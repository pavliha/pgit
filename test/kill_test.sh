#!/usr/bin/env bash
set -uo pipefail

ADMIN="${GROVE_ADMIN_DSN:-postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/postgres}"
DSN="${GROVE_KILL_DSN:-postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/grove_kill}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/lib.sh"
q()   { psql "$DSN" -X -q -At -c "$1"; }

psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS grove_kill" -c "CREATE DATABASE grove_kill" >/dev/null
psql "$DSN" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null
psql "$DSN" -X -q >/dev/null <<'SQL'
CREATE TABLE t (id int PRIMARY KEY, name text);
INSERT INTO t SELECT g, 'row-' || g FROM generate_series(1, 200) g;
SELECT grove.track('t');
SELECT grove.commit('base', 'pavlo');
SELECT grove.branch('feature');
SQL

BEFORE=$(q "SELECT encode(grove.resolve('main'),'hex')")

psql "$DSN" -X -q >/dev/null 2>&1 <<'SQL' &
SET application_name = 'grove_victim';
BEGIN;
UPDATE t SET name = 'half done' WHERE id <= 50;
SELECT grove.commit('victim commit', 'victim');
SELECT grove.rebase('feature');
SELECT pg_sleep(120);
COMMIT;
SQL

for _ in $(seq 1 50); do
  PID=$(q "SELECT pid FROM pg_stat_activity WHERE application_name='grove_victim' AND state='active' AND query LIKE '%pg_sleep%'")
  [ -n "$PID" ] && break
  sleep 0.2
done

is "AC-REPLAY-11: the victim session is mid-operation with an open transaction" "$([ -n "$PID" ] && echo yes)" "yes"

is "AC-REPLAY-11: another session sees the ref unmoved while the work is uncommitted" \
   "$(q "SELECT encode(grove.resolve('main'),'hex')")" "$BEFORE"

psql "$DSN" -X -q -At -c "SELECT pg_terminate_backend($PID)" >/dev/null
wait 2>/dev/null

for _ in $(seq 1 50); do
  STILL=$(q "SELECT count(*) FROM pg_stat_activity WHERE pid = $PID")
  [ "$STILL" = "0" ] && break
  sleep 0.2
done

is "AC-REPLAY-11: the killed backend is gone" "$STILL" "0"

is "AC-REPLAY-11: the ref is still unmoved after the kill, not left at a partial state" \
   "$(q "SELECT encode(grove.resolve('main'),'hex')")" "$BEFORE"

is "AC-REPLAY-11: no rebase state survived the kill" \
   "$(q "SELECT count(*) FROM grove.rebase_state")" "0"

is "AC-REPLAY-11: no commits from the killed session survived" \
   "$(q "SELECT count(*) FROM grove.commits")" "1"

is "AC-REPLAY-11: the killed backend holds no locks" \
   "$(q "SELECT count(*) FROM pg_locks WHERE pid = $PID")" "0"

psql "$DSN" -X -q >/dev/null <<'SQL'
UPDATE t SET name = 'after the kill' WHERE id = 1;
SELECT grove.commit('recovery commit', 'pavlo');
SQL

is "AC-REPLAY-11: a fresh session can commit afterwards, the repository is not wedged" \
   "$(q "SELECT count(*) FROM grove.commits")" "2"

is "AC-REPLAY-11: the recovery commit produced a correct tree" \
   "$(q "SELECT (grove.write_tree('t') = (SELECT root_hash FROM grove.trees WHERE commit_sha = grove.resolve('main') AND tbl='t'))::text")" "true"

psql "$ADMIN" -X -q -c "DROP DATABASE grove_kill" >/dev/null

suite_end KILL 9
