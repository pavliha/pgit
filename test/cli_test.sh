#!/usr/bin/env bash
set -uo pipefail

ADMIN="${PGIT_ADMIN_DSN:-postgresql://postgres:pgit@localhost:5460/postgres}"
export PGIT_DSN="${PGIT_CLI_DSN:-postgresql://postgres:pgit@localhost:5460/pgit_cli}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PGIT="$DIR/bin/pgit"
N=0; FAILED=0

ok()  { N=$((N+1)); printf 'ok %d - %s\n' "$N" "$1"; }
nok() { N=$((N+1)); FAILED=1; printf 'not ok %d - %s\n' "$N" "$1"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1 (want '$3', got '$2')"; fi; }
like(){ if [[ "$2" =~ $3 ]]; then ok "$1"; else nok "$1 (got '$2')"; fi; }

psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS pgit_cli" -c "CREATE DATABASE pgit_cli" >/dev/null
psql "$PGIT_DSN" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null
psql "$PGIT_DSN" -X -q -c "CREATE TABLE t (id int PRIMARY KEY, name text, hits int)" \
                  -c "INSERT INTO t SELECT g, 'row-'||g, 0 FROM generate_series(1,20) g" >/dev/null

"$PGIT" track t >/dev/null
out=$("$PGIT" commit -m "base")
like "AC-CLI-01: commit prints a git shaped line" "$out" '^\[main [0-9a-f]{7}\] base$'

A=$(psql "$PGIT_DSN" -X -q -At -c "SELECT encode(pgit.resolve('main'),'hex')")

is "AC-CLI-01: status reports a clean tree" "$("$PGIT" status | tail -1)" "nothing to commit, working tree clean"

like "AC-CLI-01: log --oneline starts with a seven character sha" \
     "$("$PGIT" log --oneline | head -1)" '^[0-9a-f]{7} base$'

"$PGIT" log --graph >/dev/null 2>/tmp/pgit_err; rc=$?
is "AC-CLI-02: an unimplemented flag exits 129" "$rc" "129"
like "AC-CLI-02: the error names the flag rather than ignoring it" "$(cat /tmp/pgit_err)" 'unsupported flag --graph'

"$PGIT" frobnicate >/dev/null 2>/tmp/pgit_err; rc=$?
is "AC-CLI-02: an unknown command exits 129" "$rc" "129"
like "AC-CLI-02: the error names the command" "$(cat /tmp/pgit_err)" "'frobnicate' is not a pgit command"

"$PGIT" commit >/dev/null 2>/tmp/pgit_err; rc=$?
is "AC-CLI-02: commit without -m is refused" "$rc" "129"

psql "$PGIT_DSN" -X -q -c "UPDATE t SET hits = 1 WHERE id <= 3" >/dev/null
"$PGIT" commit -m "touch three rows" >/dev/null
B=$(psql "$PGIT_DSN" -X -q -At -c "SELECT encode(pgit.resolve('main'),'hex')")

"$PGIT" diff "$A" "$B" --exit-code >/dev/null; rc=$?
is "AC-CLI-03: diff --exit-code returns 1 when there are differences" "$rc" "1"

"$PGIT" diff "$B" "$B" --exit-code >/dev/null; rc=$?
is "AC-CLI-03: diff --exit-code returns 0 when there are none" "$rc" "0"

line=$("$PGIT" diff "$A" "$B" --numstat | head -1)
is "AC-CLI-04: numstat is three tab separated fields" "$(printf '%s' "$line" | awk -F'\t' '{print NF}')" "3"
is "AC-CLI-04: numstat reports three changed rows" "$(printf '%s' "$line" | cut -f1)" "3"

is "AC-CLI-01: name-status marks the table as modified" \
   "$("$PGIT" diff "$A" "$B" --name-status | head -1 | cut -f1)" "M"

"$PGIT" branch feature >/dev/null
like "AC-CLI-01: branch marks the checked out branch with an asterisk" \
     "$("$PGIT" branch | tr '\n' ' ')" '\* main'

is "AC-CLI-01: blame names the author of a column" \
   "$("$PGIT" blame t 1 | head -1 | grep -c 'hits')" "1"

psql "$ADMIN" -X -q -c "DROP DATABASE pgit_cli" >/dev/null

echo
echo "cli: $((N - (FAILED == 1 ? 1 : 0)))/$N checks"
[ $FAILED -eq 0 ] && echo "CLI GREEN" || echo "CLI RED"
exit $FAILED
