#!/usr/bin/env bash
set -uo pipefail

ADMIN="${GROVE_ADMIN_DSN:-postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/postgres}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
O="postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/grove_origin"
C="postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/grove_clone"
. "$(dirname "$0")/lib.sh"
qo(){ psql "$O" -X -q -At -c "$1" 2>&1; }
qc(){ psql "$C" -X -q -At -c "$1" 2>&1; }
runb(){ { echo "SET client_min_messages=warning;"; printf '\\set b `cat %s`\n' "$2"; echo "$3"; } | psql "$1" -X -q -At 2>&1 | grep -v '^SET$'; }

for d in grove_origin grove_clone; do
  psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS $d" -c "CREATE DATABASE $d" >/dev/null 2>&1
done
psql "$O" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1
psql "$C" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1

DDL="CREATE TABLE t (id int PRIMARY KEY, name text, hits int)"
psql "$O" -X -q -c "$DDL" -c "SELECT grove.track('t')" >/dev/null
psql "$C" -X -q -c "$DDL" -c "SELECT grove.track('t')" >/dev/null

psql "$O" -X -q >/dev/null <<'SQL'
INSERT INTO t SELECT g, 'row-'||g, 0 FROM generate_series(1,300) g;
SELECT grove.commit('first','alice');
UPDATE t SET hits=1 WHERE id=7;
SELECT grove.commit('second','alice');
SQL

qo "SELECT grove.bundle(ARRAY['main'])" > /tmp/grove_b1.json
is "remote: the bundle is a single self contained value" "$(head -c 1 /tmp/grove_b1.json)" "{"

runb "$C" /tmp/grove_b1.json "SELECT grove.receive(:'b'::jsonb);" >/dev/null
is "remote: fetching from a remote that was never added is refused, rather than inventing it" \
   "$(runb "$C" /tmp/grove_b1.json "SELECT grove.fetch('never-added', :'b'::jsonb);" 2>&1 | grep -c 'no remote named')" "1"
is "remote: the clone received both commits" "$(qc "SELECT count(*) FROM grove.commits")" "2"
is "remote: the clone's main points where origin's does" \
   "$(qc "SELECT encode(grove.resolve('main'),'hex')")" "$(qo "SELECT encode(grove.resolve('main'),'hex')")"
is "remote: fsck is clean on the clone after receiving" "$(qc "SELECT count(*) FROM grove.fsck()")" "0"

qc "SELECT grove.reset('main','hard')" >/dev/null
is "remote: the clone materialised the same number of rows" "$(qc "SELECT count(*) FROM t")" "300"
is "remote: the clone's tree hashes identically to origin's" \
   "$(qc "SELECT encode(grove.write_tree('t'),'hex')")" "$(qo "SELECT encode(grove.write_tree('t'),'hex')")"
is "remote: the edited row came across intact" "$(qc "SELECT hits FROM t WHERE id=7")" "1"

psql "$O" -X -q >/dev/null <<'SQL'
UPDATE t SET hits=2 WHERE id=9;
SELECT grove.commit('third','alice');
SQL

HAVE=$(qc "SELECT COALESCE(jsonb_agg(encode(sha,'hex'))::text,'[]') FROM grove.commits")
HAVEX="COALESCE((SELECT array_agg(decode(x,'hex')) FROM jsonb_array_elements_text('$HAVE'::jsonb) x),'{}'::bytea[])"

qo "SELECT grove.bundle(ARRAY['main'], $HAVEX)" > /tmp/grove_b2.json

FULL=$(qo "SELECT jsonb_array_length(grove.bundle(ARRAY['main']) -> 'nodes')")
INCR=$(qo "SELECT jsonb_array_length(grove.bundle(ARRAY['main'], $HAVEX) -> 'nodes')")
if [ "$INCR" -lt "$FULL" ]; then
  ok "remote: an incremental fetch sends fewer nodes ($INCR against $FULL)"
else
  nok "remote: an incremental fetch sends fewer nodes ($INCR against $FULL)"
fi

qc "SELECT grove.remote_add('origin','the origin database, moved by hand')" >/dev/null
runb "$C" /tmp/grove_b2.json "SELECT grove.fetch('origin', :'b'::jsonb);" >/dev/null
is "remote: fetch updated the remote tracking ref only" \
   "$(qc "SELECT encode(grove.resolve('remotes/origin/main'),'hex')")" "$(qo "SELECT encode(grove.resolve('main'),'hex')")"
is "remote: fetch left the local branch alone" "$(qc "SELECT count(*) FROM grove.commits WHERE sha = grove.resolve('main')")" "1"

psql "$C" -X -q >/dev/null <<'SQL'
UPDATE t SET name='clone only' WHERE id=50;
SELECT grove.commit('clone diverges','bob');
SQL
qc "SELECT grove.bundle(ARRAY['main'])" > /tmp/grove_b3.json
OUT=$(runb "$O" /tmp/grove_b3.json "SELECT grove.receive(:'b'::jsonb);")
is "remote: a non fast forward push is refused" "$(printf '%s' "$OUT" | grep -c 'not a fast forward')" "1"

OUT=$(runb "$O" /tmp/grove_b3.json "SELECT grove.receive(:'b'::jsonb, true);")
is "remote: forcing overrides the check" "$(printf '%s' "$OUT" | grep -c 'not a fast forward')" "0"

python3 - <<'PY'
import json
b=json.load(open('/tmp/grove_b1.json'))
if b['nodes']:
    b['nodes'][0]['entries']=[{"k":"00","h":"deadbeef","v":{}}]
json.dump(b,open('/tmp/grove_bad.json','w'))
PY
psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS grove_bad" -c "CREATE DATABASE grove_bad" >/dev/null 2>&1
B="postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/grove_bad"
psql "$B" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1
OUT=$(runb "$B" /tmp/grove_bad.json "SELECT grove.unbundle(:'b'::jsonb);")
is "remote: a tampered bundle is rejected by content hash" \
   "$(printf '%s' "$OUT" | grep -c 'does not hash to its content')" "1"

python3 - <<'PY2'
import json
b=json.load(open('/tmp/grove_b1.json'))
b['nodes']=b['nodes'][:len(b['nodes'])//2]
json.dump(b,open('/tmp/grove_short.json','w'))
PY2
psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS grove_short" -c "CREATE DATABASE grove_short" >/dev/null 2>&1
S2="postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/grove_short"
psql "$S2" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1
OUT=$(runb "$S2" /tmp/grove_short.json "SELECT grove.unbundle(:'b'::jsonb);")
is "remote: a bundle missing nodes is refused, not stored with dangling references" \
   "$(printf '%s' "$OUT" | grep -c 'bundle is incomplete')" "1"
is "remote: and nothing from it was kept" \
   "$(psql "$S2" -X -q -At -c 'SELECT count(*) FROM grove.nodes')" "0"

python3 - <<'PY3'
import json, copy, random
b = json.load(open('/tmp/grove_b1.json'))
random.seed(7)
def w(name, mut):
    c = copy.deepcopy(b); mut(c); json.dump(c, open('/tmp/grove_mal_%s.json' % name, 'w'))
w('reordered',   lambda c: random.shuffle(c['nodes']))
w('dupnodes',    lambda c: c['nodes'].extend(c['nodes'][:3]))
w('nosettings',  lambda c: c.pop('settings', None))
w('refdangling', lambda c: c['refs'].update({k: 'ab'*32 for k in c['refs']}))
w('notrees',     lambda c: c.__setitem__('trees', []))
w('noschemas',   lambda c: c.__setitem__('schemas', []))
w('fpforged',    lambda c: [s.__setitem__('fp', 'ab' * 32) for s in c['schemas']])
def rekey(c):
    for n in c['nodes']:
        if n['level'] == 0 and len(n['entries']) > 2:
            e = n['entries'][1]
            raw = bytes.fromhex(e['k']).decode()
            if raw.endswith('|'):
                e['k'] = (raw[:-1] + '}').encode().hex()
                return
w('rekeyed',     rekey)
def pad(c):
    import hashlib
    leaf = next(n for n in c['nodes'] if n['level'] == 0 and len(n['entries']) > 1)
    for drop in range(1, min(4, len(leaf['entries']))):
        ents = leaf['entries'][:-drop]
        h = hashlib.sha256(b''.join(bytes.fromhex(e['h']) for e in sorted(ents, key=lambda e: e['k'])))
        c['nodes'].append({'hash': h.hexdigest(), 'level': 0, 'entries': ents})
w('padded',      pad)
w('pkswap',      lambda c: [s.__setitem__('pk', ['name']) for s in c['schemas']])
w('pkbogus',     lambda c: [s.__setitem__('pk', ['nonexistent_col']) for s in c['schemas']])
PY3

mal() {
  psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS grove_mal WITH (FORCE)" -c "CREATE DATABASE grove_mal" >/dev/null 2>&1
  M="postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/grove_mal"
  psql "$M" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1
  runb "$M" "/tmp/grove_mal_$1.json" "SELECT grove.clone_from(:'b'::jsonb, 'main');" 2>&1
}

is "remote: reordering the nodes in a bundle changes nothing" \
   "$(mal reordered | grep -ci error)" "0"
is "remote: a bundle carrying duplicate nodes is still accepted" \
   "$(mal dupnodes | grep -ci error)" "0"
is "remote: a bundle with no settings block is refused, so the settings check cannot be deleted away" \
   "$(mal nosettings | grep -c 'carries no settings')" "1"
is "remote: a ref pointing at a commit the bundle omits is refused by name, not by a foreign key" \
   "$(mal refdangling | grep -c 'pointing at commits it does not carry')" "1"
is "remote: a bundle whose trees are missing is refused rather than cloning an empty table" \
   "$(mal notrees | grep -c 'tree without a shape or a shape without a tree')" "1"
is "remote: a bundle whose schemas are missing is refused rather than cloning no table at all" \
   "$(mal noschemas | grep -c 'tree without a shape or a shape without a tree')" "1"

python3 - <<'PY4'
import json
b = json.load(open('/tmp/grove_b1.json'))
json.dump(b, open('/tmp/grove_mal_honest.json', 'w'))
leaf = next(n for n in b['nodes'] if n.get('level') == 0 and n.get('entries'))
leaf['entries'][0]['v'] = {k: ('ATTACKER' if isinstance(v, str) else v)
                           for k, v in leaf['entries'][0]['v'].items()}
json.dump(b, open('/tmp/grove_mal_datatamper.json', 'w'))
PY4

is "remote: a row filed under a key that is not its own primary key is refused" \
   "$(mal rekeyed | grep -c 'not their own primary key')" "1"
is "remote: valid nodes that no tree references are refused, a bundle cannot pad the store" \
   "$(mal padded | grep -c 'none of its trees reference')" "1"
is "remote: a forged schema fingerprint is refused, it must match the shape stored beside it" \
   "$(mal fpforged | grep -c 'does not match its own fingerprint')" "1"
is "remote: a bundle that repoints a table's primary key is refused before anything is materialised" \
   "$(mal pkswap | grep -c 'not their own primary key')" "1"
is "remote: a primary key naming a column the table does not have is refused" \
   "$(mal pkbogus | grep -c 'named in key does not exist')" "1"
is "remote: a bundle whose row images were altered is refused, even though every node still hashes" \
   "$(mal datatamper | grep -c 'do not hash to the values recorded beside them')" "1"

malf() {
  psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS grove_mal WITH (FORCE)" -c "CREATE DATABASE grove_mal" >/dev/null 2>&1
  M="postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/grove_mal"
  psql "$M" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1
  psql "$M" -X -q -c "$DDL" -c "SELECT grove.track('t')" >/dev/null 2>&1
  psql "$M" -X -q -At >/dev/null 2>&1 <<'SQL'
INSERT INTO t VALUES (999999, 'local', 1);
SELECT grove.commit('local work', 'carol');
SELECT grove.remote_add('origin', 'somewhere');
SQL
  runb "$M" "/tmp/grove_mal_$1.json" "SELECT grove.$2;" 2>&1
}

is "remote: fetching altered row images into a repo that already has history is refused" \
   "$(malf datatamper "fetch('origin', :'b'::jsonb)" | grep -c 'do not hash to the values recorded beside them')" "1"
is "remote: receiving altered row images is refused, the push path checks images too" \
   "$(malf datatamper "receive(:'b'::jsonb)" | grep -c 'do not hash to the values recorded beside them')" "1"
is "remote: fetching an honest bundle into a repo with history still works" \
   "$(malf honest "fetch('origin', :'b'::jsonb)" | grep -ci error)" "0"

python3 - <<'PY5'
import json, copy
b = json.load(open('/tmp/grove_b1.json'))
c = copy.deepcopy(b)
for cm in c['commits']:
    cm['author'] = 'trusted-reviewer'; cm['message'] = 'Approved by security team'
json.dump(c, open('/tmp/grove_mal_forged.json', 'w'))
d = copy.deepcopy(b)
leaf = next(n for n in d['nodes'] if n['level'] == 0)
d['trees'][0]['root'] = leaf['hash']
json.dump(d, open('/tmp/grove_mal_rootswap.json', 'w'))
PY5

is "remote: rewriting a commit's author and message is refused, the sha no longer covers them" \
   "$(mal forged | grep -c 'do not hash to their own author')" "1"
is "remote: repointing a commit's tree root is refused, because the commit sha covers the roots" \
   "$(mal rootswap | grep -c 'do not hash to their own author')" "1"

psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS grove_virgin" -c "CREATE DATABASE grove_virgin" >/dev/null 2>&1
V="postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/grove_virgin"
psql "$V" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1
qv(){ psql "$V" -X -q -At -c "$1" 2>&1; }

is "clone: the target starts with no tables of its own" "$(qv "SELECT to_regclass('t') IS NULL")" "t"

qo "SELECT grove.bundle(ARRAY['main'])" > /tmp/grove_b4.json
MADE=$(runb "$V" /tmp/grove_b4.json "SELECT grove.clone_from(:'b'::jsonb);")
is "clone: one command created the table from the recorded shape" "$MADE" "1"
is "clone: the table is tracked" "$(qv "SELECT count(*) FROM grove.tracked")" "1"
is "clone: HEAD is on the cloned branch" "$(qv "SELECT grove.head()")" "main"
is "clone: every row arrived" "$(qv "SELECT count(*) FROM t")" "300"
is "clone: the materialised table hashes to exactly what the cloned commit records" \
   "$(qv "SELECT encode(grove.write_tree('t'),'hex')")" \
   "$(qo "SELECT encode(x.root_hash,'hex') FROM grove.trees x WHERE x.commit_sha=grove.resolve('main') AND x.tbl='t'")"
is "clone: fsck is clean" "$(qv "SELECT count(*) FROM grove.fsck()")" "0"
is "clone: the working tree is not dirty" "$(qv "SELECT grove.is_dirty()")" "f"
is "clone: the created table keeps the original column order, so a positional INSERT still lands right" \
   "$(qv "SELECT string_agg(attname,',' ORDER BY attnum) FROM pg_attribute WHERE attrelid='t'::regclass AND attnum>0 AND NOT attisdropped")" "id,name,hits"
OUT=$(runb "$V" /tmp/grove_b4.json "SELECT grove.clone_from(:'b'::jsonb);")
is "clone: cloning over an existing history is refused" \
   "$(printf '%s' "$OUT" | grep -c 'needs an empty history')" "1"

psql "$O" -X -q -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
SELECT grove.reset('main','hard');
SELECT grove.branch('oct1');
SELECT grove.branch('oct2');
SELECT grove.checkout('oct1');
UPDATE t SET name='from oct1' WHERE id=101;
SELECT grove.commit('oct1 edit','alice');
SELECT grove.checkout('oct2');
UPDATE t SET name='from oct2' WHERE id=102;
SELECT grove.commit('oct2 edit','alice');
SELECT grove.checkout('main');
SELECT grove.merge_octopus(ARRAY['oct1','oct2']);
SQL

is "octopus: origin built a merge commit with three parents" \
   "$(qo "SELECT count(*) FROM grove.parents_of(grove.resolve('main'))")" "3"

psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS grove_oct" -c "CREATE DATABASE grove_oct" >/dev/null 2>&1
P="postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/grove_oct"
psql "$P" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1
qp(){ psql "$P" -X -q -At -c "$1" 2>&1; }

qo "SELECT grove.bundle(ARRAY['main','oct1','oct2'])" > /tmp/grove_b5.json
runb "$P" /tmp/grove_b5.json "SELECT grove.clone_from(:'b'::jsonb);" >/dev/null

is "octopus: a bundle carries every parent of a merge, not just the first two" \
   "$(qp "SELECT count(*) FROM grove.parents_of(grove.resolve('main'))")" "3"
is "octopus: the received parents are the same commits origin recorded" \
   "$(qp "SELECT string_agg(encode(p.parent,'hex'),',' ORDER BY p.ord) FROM grove.parents_of(grove.resolve('main')) p")" \
   "$(qo "SELECT string_agg(encode(p.parent,'hex'),',' ORDER BY p.ord) FROM grove.parents_of(grove.resolve('main')) p")"
is "octopus: fsck on the receiver sees no missing parent" "$(qp "SELECT count(*) FROM grove.fsck()")" "0"
is "octopus: both branches' rows survived the transfer" \
   "$(qp "SELECT string_agg(name,',' ORDER BY id) FROM t WHERE id IN (101,102)")" "from oct1,from oct2"

for d in grove_origin grove_clone grove_bad grove_short grove_mal grove_virgin grove_oct; do psql "$ADMIN" -X -q -c "DROP DATABASE $d" >/dev/null; done
rm -f /tmp/grove_b*.json

psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS grove_pruned WITH (FORCE)" -c "CREATE DATABASE grove_pruned" >/dev/null 2>&1
psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS grove_pruned_clone WITH (FORCE)" -c "CREATE DATABASE grove_pruned_clone" >/dev/null 2>&1
P="postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/grove_pruned"
PC="postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/grove_pruned_clone"
psql "$P" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1
psql "$PC" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1
psql "$P" -X -q -c "$DDL" -c "SELECT grove.track('t')" >/dev/null 2>&1
psql "$P" -X -q -At >/dev/null 2>&1 <<'SQL'
INSERT INTO t SELECT g, 'row-'||g, 0 FROM generate_series(1,300) g;
SELECT grove.commit('old one','alice', now() - interval '10 days');
UPDATE t SET hits = 1 WHERE id = 1;
SELECT grove.commit('old two','alice', now() - interval '9 days');
UPDATE t SET hits = 2 WHERE id = 2;
SELECT grove.commit('recent','alice', now());
SELECT grove.prune(now() - interval '5 days');
SQL
is "remote: pruning records the parent link it severs" \
   "$(psql "$P" -X -q -At -c 'SELECT count(*) FROM grove.shallow')" "1"
is "remote: a pruned repository still passes fsck" \
   "$(psql "$P" -X -q -At -c 'SELECT count(*) FROM grove.fsck()')" "0"
psql "$P" -X -q -At -c "SELECT grove.bundle(ARRAY['main'])" > /tmp/grove_pruned.json 2>&1
is "remote: a pruned repository can still be cloned, its commits verify against the recorded boundary" \
   "$(runb "$PC" /tmp/grove_pruned.json "SELECT grove.clone_from(:'b'::jsonb, 'main');" | grep -ci error)" "0"
is "remote: and the clone has every row" \
   "$(psql "$PC" -X -q -At -c 'SELECT count(*) FROM t')" "300"
is "remote: and the clone carries the boundary too, so it can be cloned onward" \
   "$(psql "$PC" -X -q -At -c 'SELECT count(*) FROM grove.shallow')" "1"

suite_end REMOTE 53
