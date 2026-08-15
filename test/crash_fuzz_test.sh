#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"

ADMIN="${PGIT_ADMIN_DSN:-postgresql://postgres:pgit@localhost:5460/postgres}"
D="postgresql://postgres:pgit@localhost:5460/pgit_crash"
KILLS="${CRASH_KILLS:-12}"

psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS pgit_crash WITH (FORCE)" \
                -c "CREATE DATABASE pgit_crash" >/dev/null
psql "$D" -X -q -v ON_ERROR_STOP=1 -f "$DIR/../sql/install.sql" >/dev/null 2>&1
psql "$D" -X -q -c "CREATE TABLE k1 (id int PRIMARY KEY, v text, n int)" >/dev/null
psql "$D" -X -q -At -c "SELECT pgit.track('k1')" >/dev/null
psql "$D" -X -q -c "INSERT INTO k1 SELECT g,'v'||g,0 FROM generate_series(1,2000) g" >/dev/null
psql "$D" -X -q -At -c "SELECT pgit.commit('base','main')" >/dev/null
psql "$D" -X -q -At -c "SELECT pgit.branch('side', pgit.resolve('main'))" >/dev/null

violations=0
killed=0

for i in $(seq 1 "$KILLS"); do
  case $((RANDOM % 5)) in
    0) WORK="UPDATE k1 SET n = n + 1 WHERE id % 7 = 0; SELECT pgit.commit('c$i','main');" ;;
    1) WORK="DELETE FROM k1 WHERE id = $((100 + i)); SELECT pgit.commit('d$i','main');" ;;
    2) WORK="INSERT INTO k1 VALUES ($((9000 + i)),'new',1); SELECT pgit.commit('i$i','main');" ;;
    3) WORK="SELECT pgit.repack();" ;;
    *) WORK="UPDATE k1 SET v = 'x$i' WHERE id % 11 = 0; SELECT pgit.commit('u$i','main'); SELECT pgit.revert(pgit.resolve('main'));" ;;
  esac

  psql "$D" -X -q >/dev/null 2>&1 <<SQL &
SET application_name = 'crash_victim';
BEGIN;
$WORK
SELECT pg_sleep(0.4);
COMMIT;
SQL

  sleep "0.$(( RANDOM % 4 ))"

  PID=$(psql "$D" -X -At -c \
    "SELECT pid FROM pg_stat_activity WHERE application_name='crash_victim' LIMIT 1" 2>/dev/null)
  if [ -n "$PID" ]; then
    psql "$D" -X -q -At -c "SELECT pg_terminate_backend($PID)" >/dev/null 2>&1
    killed=$((killed + 1))
  fi
  wait 2>/dev/null

  BAD=$(psql "$D" -X -At -c "
    SELECT (SELECT count(*) FROM pgit.fsck())
         + (SELECT count(*) FROM pgit.trees t
            WHERE t.commit_sha = pgit.resolve('main')
              AND pgit.write_tree(t.tbl::regclass) IS DISTINCT FROM t.root_hash)" 2>&1)
  if [ "$BAD" != "0" ]; then
    violations=$((violations + 1))
    echo "  crash $i: invariant broken after killing during: $(echo "$WORK" | head -c 60)"
  fi
done

cmp_pos() { if [ "$1" -gt 0 ]; then ok "$2"; else nok "$2 (got $1)"; fi; }

cmp_pos "$killed" "crash: $killed of $KILLS sessions were killed mid-operation"

is "crash: every kill left fsck clean and every tree matching a rebuild" "$violations" "0"

is "crash: no half-applied change survived the rollbacks" \
   "$(psql "$D" -X -At -c "SELECT count(*) FROM pgit.changes WHERE commit_sha IS NULL")" "0"

is "crash: the branch still resolves and its history is reachable" \
   "$(psql "$D" -X -At -c "SELECT (pgit.resolve('main') IS NOT NULL)")" "t"

is "crash: a commit still works afterwards" \
   "$(psql "$D" -X -At -c "UPDATE k1 SET n = n + 1 WHERE id = 1; SELECT (pgit.commit('after crashes','main') IS NOT NULL)" | tail -1)" "t"

suite_end CRASH-FUZZ 5
