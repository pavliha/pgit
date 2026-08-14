#!/usr/bin/env bash
set -uo pipefail

ADMIN="${PGIT_ADMIN_DSN:-postgresql://postgres:pgit@localhost:5460/postgres}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
O="postgresql://postgres:pgit@localhost:5460/pgit_origin"
C="postgresql://postgres:pgit@localhost:5460/pgit_clone"
N=0; FAILED=0
ok(){ N=$((N+1)); printf 'ok %d - %s\n' "$N" "$1"; }
nok(){ N=$((N+1)); FAILED=1; printf 'not ok %d - %s\n' "$N" "$1"; }
is(){ if [ "$2" = "$3" ]; then ok "$1"; else nok "$1 (want '$3', got '$2')"; fi; }
qo(){ psql "$O" -X -q -At -c "$1" 2>&1; }
qc(){ psql "$C" -X -q -At -c "$1" 2>&1; }
runb(){ { printf '\\set b `cat %s`\n' "$2"; echo "$3"; } | psql "$1" -X -q -At 2>&1; }

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
B="postgresql://postgres:pgit@localhost:5460/pgit_bad"
psql "$B" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1
OUT=$(runb "$B" /tmp/pgit_bad.json "SELECT pgit.unbundle(:'b'::jsonb);")
is "remote: a tampered bundle is rejected by content hash" \
   "$(printf '%s' "$OUT" | grep -c 'does not hash to its content')" "1"

for d in pgit_origin pgit_clone pgit_bad; do psql "$ADMIN" -X -q -c "DROP DATABASE $d" >/dev/null; done
rm -f /tmp/pgit_b*.json

echo
[ $FAILED -eq 0 ] && echo "REMOTE GREEN ($N checks)" || echo "REMOTE RED"
exit $FAILED
