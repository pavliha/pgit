#!/usr/bin/env bash
set -uo pipefail

ADMIN="${PGIT_ADMIN_DSN:-postgresql://postgres:pgit@${PGIT_HOST:-localhost:5460}/postgres}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
O="postgresql://postgres:pgit@${PGIT_HOST:-localhost:5460}/pgit_origin"
C="postgresql://postgres:pgit@${PGIT_HOST:-localhost:5460}/pgit_clone"
. "$(dirname "$0")/lib.sh"
qo(){ psql "$O" -X -q -At -c "$1" 2>&1; }
qc(){ psql "$C" -X -q -At -c "$1" 2>&1; }
runb(){ { echo "SET client_min_messages=warning;"; printf '\\set b `cat %s`\n' "$2"; echo "$3"; } | psql "$1" -X -q -At 2>&1 | grep -v '^SET$'; }

for d in pgit_origin pgit_clone; do
  psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS $d" -c "CREATE DATABASE $d" >/dev/null 2>&1
done
psql "$O" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1
psql "$C" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1

DDL="CREATE TABLE t (id int PRIMARY KEY, name text, hits int)"
psql "$O" -X -q -c "$DDL" -c "SELECT pgit.track('t')" >/dev/null
psql "$C" -X -q -c "$DDL" -c "SELECT pgit.track('t')" >/dev/null

psql "$O" -X -q >/dev/null <<'SQL'
INSERT INTO t SELECT g, 'row-'||g, 0 FROM generate_series(1,300) g;
SELECT pgit.commit('first','alice');
UPDATE t SET hits=1 WHERE id=7;
SELECT pgit.commit('second','alice');
SQL

qo "SELECT pgit.bundle(ARRAY['main'])" > /tmp/pgit_b1.json
is "remote: the bundle is a single self contained value" "$(head -c 1 /tmp/pgit_b1.json)" "{"

runb "$C" /tmp/pgit_b1.json "SELECT pgit.receive(:'b'::jsonb);" >/dev/null
is "remote: fetching from a remote that was never added is refused, rather than inventing it" \
   "$(runb "$C" /tmp/pgit_b1.json "SELECT pgit.fetch('never-added', :'b'::jsonb);" 2>&1 | grep -c 'no remote named')" "1"
is "remote: the clone received both commits" "$(qc "SELECT count(*) FROM pgit.commits")" "2"
is "remote: the clone's main points where origin's does" \
   "$(qc "SELECT encode(pgit.resolve('main'),'hex')")" "$(qo "SELECT encode(pgit.resolve('main'),'hex')")"
is "remote: fsck is clean on the clone after receiving" "$(qc "SELECT count(*) FROM pgit.fsck()")" "0"

qc "SELECT pgit.reset('main','hard')" >/dev/null
is "remote: the clone materialised the same number of rows" "$(qc "SELECT count(*) FROM t")" "300"
is "remote: the clone's tree hashes identically to origin's" \
   "$(qc "SELECT encode(pgit.write_tree('t'),'hex')")" "$(qo "SELECT encode(pgit.write_tree('t'),'hex')")"
is "remote: the edited row came across intact" "$(qc "SELECT hits FROM t WHERE id=7")" "1"

psql "$O" -X -q >/dev/null <<'SQL'
UPDATE t SET hits=2 WHERE id=9;
SELECT pgit.commit('third','alice');
SQL

HAVE=$(qc "SELECT COALESCE(jsonb_agg(encode(sha,'hex'))::text,'[]') FROM pgit.commits")
HAVEX="COALESCE((SELECT array_agg(decode(x,'hex')) FROM jsonb_array_elements_text('$HAVE'::jsonb) x),'{}'::bytea[])"

qo "SELECT pgit.bundle(ARRAY['main'], $HAVEX)" > /tmp/pgit_b2.json

FULL=$(qo "SELECT jsonb_array_length(pgit.bundle(ARRAY['main']) -> 'nodes')")
INCR=$(qo "SELECT jsonb_array_length(pgit.bundle(ARRAY['main'], $HAVEX) -> 'nodes')")
if [ "$INCR" -lt "$FULL" ]; then
  ok "remote: an incremental fetch sends fewer nodes ($INCR against $FULL)"
else
  nok "remote: an incremental fetch sends fewer nodes ($INCR against $FULL)"
fi

qc "SELECT pgit.remote_add('origin','the origin database, moved by hand')" >/dev/null
runb "$C" /tmp/pgit_b2.json "SELECT pgit.fetch('origin', :'b'::jsonb);" >/dev/null
is "remote: fetch updated the remote tracking ref only" \
   "$(qc "SELECT encode(pgit.resolve('remotes/origin/main'),'hex')")" "$(qo "SELECT encode(pgit.resolve('main'),'hex')")"
is "remote: fetch left the local branch alone" "$(qc "SELECT count(*) FROM pgit.commits WHERE sha = pgit.resolve('main')")" "1"

psql "$C" -X -q >/dev/null <<'SQL'
UPDATE t SET name='clone only' WHERE id=50;
SELECT pgit.commit('clone diverges','bob');
SQL
qc "SELECT pgit.bundle(ARRAY['main'])" > /tmp/pgit_b3.json
OUT=$(runb "$O" /tmp/pgit_b3.json "SELECT pgit.receive(:'b'::jsonb);")
is "remote: a non fast forward push is refused" "$(printf '%s' "$OUT" | grep -c 'not a fast forward')" "1"

OUT=$(runb "$O" /tmp/pgit_b3.json "SELECT pgit.receive(:'b'::jsonb, true);")
is "remote: forcing overrides the check" "$(printf '%s' "$OUT" | grep -c 'not a fast forward')" "0"

python3 - <<'PY'
import json
b=json.load(open('/tmp/pgit_b1.json'))
if b['nodes']:
    b['nodes'][0]['entries']=[{"k":"00","h":"deadbeef","v":{}}]
json.dump(b,open('/tmp/pgit_bad.json','w'))
PY
psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS pgit_bad" -c "CREATE DATABASE pgit_bad" >/dev/null 2>&1
B="postgresql://postgres:pgit@${PGIT_HOST:-localhost:5460}/pgit_bad"
psql "$B" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1
OUT=$(runb "$B" /tmp/pgit_bad.json "SELECT pgit.unbundle(:'b'::jsonb);")
is "remote: a tampered bundle is rejected by content hash" \
   "$(printf '%s' "$OUT" | grep -c 'does not hash to its content')" "1"

python3 - <<'PY2'
import json
b=json.load(open('/tmp/pgit_b1.json'))
b['nodes']=b['nodes'][:len(b['nodes'])//2]
json.dump(b,open('/tmp/pgit_short.json','w'))
PY2
psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS pgit_short" -c "CREATE DATABASE pgit_short" >/dev/null 2>&1
S2="postgresql://postgres:pgit@${PGIT_HOST:-localhost:5460}/pgit_short"
psql "$S2" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1
OUT=$(runb "$S2" /tmp/pgit_short.json "SELECT pgit.unbundle(:'b'::jsonb);")
is "remote: a bundle missing nodes is refused, not stored with dangling references" \
   "$(printf '%s' "$OUT" | grep -c 'bundle is incomplete')" "1"
is "remote: and nothing from it was kept" \
   "$(psql "$S2" -X -q -At -c 'SELECT count(*) FROM pgit.nodes')" "0"

python3 - <<'PY3'
import json, copy, random
b = json.load(open('/tmp/pgit_b1.json'))
random.seed(7)
def w(name, mut):
    c = copy.deepcopy(b); mut(c); json.dump(c, open('/tmp/pgit_mal_%s.json' % name, 'w'))
w('reordered',   lambda c: random.shuffle(c['nodes']))
w('dupnodes',    lambda c: c['nodes'].extend(c['nodes'][:3]))
w('nosettings',  lambda c: c.pop('settings', None))
w('refdangling', lambda c: c['refs'].update({k: 'ab'*32 for k in c['refs']}))
w('notrees',     lambda c: c.__setitem__('trees', []))
w('noschemas',   lambda c: c.__setitem__('schemas', []))
PY3

mal() {
  psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS pgit_mal WITH (FORCE)" -c "CREATE DATABASE pgit_mal" >/dev/null 2>&1
  M="postgresql://postgres:pgit@${PGIT_HOST:-localhost:5460}/pgit_mal"
  psql "$M" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1
  runb "$M" "/tmp/pgit_mal_$1.json" "SELECT pgit.clone_from(:'b'::jsonb, 'main');" 2>&1
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

psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS pgit_virgin" -c "CREATE DATABASE pgit_virgin" >/dev/null 2>&1
V="postgresql://postgres:pgit@${PGIT_HOST:-localhost:5460}/pgit_virgin"
psql "$V" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1
qv(){ psql "$V" -X -q -At -c "$1" 2>&1; }

is "clone: the target starts with no tables of its own" "$(qv "SELECT to_regclass('t') IS NULL")" "t"

qo "SELECT pgit.bundle(ARRAY['main'])" > /tmp/pgit_b4.json
MADE=$(runb "$V" /tmp/pgit_b4.json "SELECT pgit.clone_from(:'b'::jsonb);")
is "clone: one command created the table from the recorded shape" "$MADE" "1"
is "clone: the table is tracked" "$(qv "SELECT count(*) FROM pgit.tracked")" "1"
is "clone: HEAD is on the cloned branch" "$(qv "SELECT pgit.head()")" "main"
is "clone: every row arrived" "$(qv "SELECT count(*) FROM t")" "300"
is "clone: the materialised table hashes to exactly what the cloned commit records" \
   "$(qv "SELECT encode(pgit.write_tree('t'),'hex')")" \
   "$(qo "SELECT encode(x.root_hash,'hex') FROM pgit.trees x WHERE x.commit_sha=pgit.resolve('main') AND x.tbl='t'")"
is "clone: fsck is clean" "$(qv "SELECT count(*) FROM pgit.fsck()")" "0"
is "clone: the working tree is not dirty" "$(qv "SELECT pgit.is_dirty()")" "f"
is "clone: the created table keeps the original column order, so a positional INSERT still lands right" \
   "$(qv "SELECT string_agg(attname,',' ORDER BY attnum) FROM pg_attribute WHERE attrelid='t'::regclass AND attnum>0 AND NOT attisdropped")" "id,name,hits"
OUT=$(runb "$V" /tmp/pgit_b4.json "SELECT pgit.clone_from(:'b'::jsonb);")
is "clone: cloning over an existing history is refused" \
   "$(printf '%s' "$OUT" | grep -c 'needs an empty history')" "1"

psql "$O" -X -q -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
SELECT pgit.reset('main','hard');
SELECT pgit.branch('oct1');
SELECT pgit.branch('oct2');
SELECT pgit.checkout('oct1');
UPDATE t SET name='from oct1' WHERE id=101;
SELECT pgit.commit('oct1 edit','alice');
SELECT pgit.checkout('oct2');
UPDATE t SET name='from oct2' WHERE id=102;
SELECT pgit.commit('oct2 edit','alice');
SELECT pgit.checkout('main');
SELECT pgit.merge_octopus(ARRAY['oct1','oct2']);
SQL

is "octopus: origin built a merge commit with three parents" \
   "$(qo "SELECT count(*) FROM pgit.parents_of(pgit.resolve('main'))")" "3"

psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS pgit_oct" -c "CREATE DATABASE pgit_oct" >/dev/null 2>&1
P="postgresql://postgres:pgit@${PGIT_HOST:-localhost:5460}/pgit_oct"
psql "$P" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1
qp(){ psql "$P" -X -q -At -c "$1" 2>&1; }

qo "SELECT pgit.bundle(ARRAY['main','oct1','oct2'])" > /tmp/pgit_b5.json
runb "$P" /tmp/pgit_b5.json "SELECT pgit.clone_from(:'b'::jsonb);" >/dev/null

is "octopus: a bundle carries every parent of a merge, not just the first two" \
   "$(qp "SELECT count(*) FROM pgit.parents_of(pgit.resolve('main'))")" "3"
is "octopus: the received parents are the same commits origin recorded" \
   "$(qp "SELECT string_agg(encode(p.parent,'hex'),',' ORDER BY p.ord) FROM pgit.parents_of(pgit.resolve('main')) p")" \
   "$(qo "SELECT string_agg(encode(p.parent,'hex'),',' ORDER BY p.ord) FROM pgit.parents_of(pgit.resolve('main')) p")"
is "octopus: fsck on the receiver sees no missing parent" "$(qp "SELECT count(*) FROM pgit.fsck()")" "0"
is "octopus: both branches' rows survived the transfer" \
   "$(qp "SELECT string_agg(name,',' ORDER BY id) FROM t WHERE id IN (101,102)")" "from oct1,from oct2"

for d in pgit_origin pgit_clone pgit_bad pgit_short pgit_mal pgit_virgin pgit_oct; do psql "$ADMIN" -X -q -c "DROP DATABASE $d" >/dev/null; done
rm -f /tmp/pgit_b*.json

suite_end REMOTE 37
