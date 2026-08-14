#!/usr/bin/env bash
set -uo pipefail

ADMIN="${PGIT_ADMIN_DSN:-postgresql://postgres:pgit@localhost:5460/postgres}"
DSN="${PGIT_KILL_DSN:-postgresql://postgres:pgit@localhost:5460/pgit_kill}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
N=0; FAILED=0

ok()  { N=$((N+1)); printf 'ok %d - %s\n' "$N" "$1"; }
nok() { N=$((N+1)); FAILED=1; printf 'not ok %d - %s\n' "$N" "$1"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1 (want '$3', got '$2')"; fi; }
q()   { psql "$DSN" -X -q -At -c "$1"; }

psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS pgit_kill" -c "CREATE DATABASE pgit_kill" >/dev/null
psql "$DSN" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null
psql "$DSN" -X -q >/dev/null <<'SQL'
CREATE TABLE t (id int PRIMARY KEY, name text);
INSERT INTO t SELECT g, 'row-' || g FROM generate_series(1, 200) g;
SELECT pgit.track('t');
SELECT pgit.commit('base', 'pavlo');
SELECT pgit.branch('feature');
SQL

BEFORE=$(q "SELECT encode(pgit.resolve('main'),'hex')")

psql "$DSN" -X -q >/dev/null 2>&1 <<'SQL' &
SET application_name = 'pgit_victim';
BEGIN;
UPDATE t SET name = 'half done' WHERE id <= 50;
SELECT pgit.commit('victim commit', 'victim');
SELECT pgit.rebase('feature');
SELECT pg_sleep(120);
COMMIT;
SQL

for _ in $(seq 1 50); do
  PID=$(q "SELECT pid FROM pg_stat_activity WHERE application_name='pgit_victim' AND state='active' AND query LIKE '%pg_sleep%'")
  [ -n "$PID" ] && break
  sleep 0.2
done

is "AC-REPLAY-11: the victim session is mid-operation with an open transaction" "$([ -n "$PID" ] && echo yes)" "yes"

is "AC-REPLAY-11: another session sees the ref unmoved while the work is uncommitted" \
   "$(q "SELECT encode(pgit.resolve('main'),'hex')")" "$BEFORE"

psql "$DSN" -X -q -At -c "SELECT pg_terminate_backend($PID)" >/dev/null
wait 2>/dev/null

for _ in $(seq 1 50); do
  STILL=$(q "SELECT count(*) FROM pg_stat_activity WHERE pid = $PID")
  [ "$STILL" = "0" ] && break
  sleep 0.2
done

is "AC-REPLAY-11: the killed backend is gone" "$STILL" "0"

is "AC-REPLAY-11: the ref is still unmoved after the kill, not left at a partial state" \
   "$(q "SELECT encode(pgit.resolve('main'),'hex')")" "$BEFORE"

is "AC-REPLAY-11: no rebase state survived the kill" \
   "$(q "SELECT count(*) FROM pgit.rebase_state")" "0"

is "AC-REPLAY-11: no commits from the killed session survived" \
   "$(q "SELECT count(*) FROM pgit.commits")" "1"

is "AC-REPLAY-11: the killed backend holds no locks" \
   "$(q "SELECT count(*) FROM pg_locks WHERE pid = $PID")" "0"

psql "$DSN" -X -q >/dev/null <<'SQL'
UPDATE t SET name = 'after the kill' WHERE id = 1;
SELECT pgit.commit('recovery commit', 'pavlo');
SQL

is "AC-REPLAY-11: a fresh session can commit afterwards, the repository is not wedged" \
   "$(q "SELECT count(*) FROM pgit.commits")" "2"

is "AC-REPLAY-11: the recovery commit produced a correct tree" \
   "$(q "SELECT (pgit.write_tree('t') = (SELECT root_hash FROM pgit.trees WHERE commit_sha = pgit.resolve('main') AND tbl='t'))::text")" "true"

psql "$ADMIN" -X -q -c "DROP DATABASE pgit_kill" >/dev/null

echo
[ $FAILED -eq 0 ] && echo "KILL GREEN ($N checks)" || echo "KILL RED"
exit $FAILED
