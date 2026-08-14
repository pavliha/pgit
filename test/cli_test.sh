#!/usr/bin/env bash
set -uo pipefail

ADMIN="${PGIT_ADMIN_DSN:-postgresql://postgres:pgit@localhost:5460/postgres}"
export PGIT_DSN="${PGIT_CLI_DSN:-postgresql://postgres:pgit@localhost:5460/pgit_cli}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PGIT="$DIR/bin/pgit"
. "$(dirname "$0")/lib.sh"

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

psql "$PGIT_DSN" -X -q >/dev/null 2>&1 <<'SQL'
CREATE TABLE m (id int PRIMARY KEY, v text);
SELECT pgit.track('m');
INSERT INTO m VALUES (1,'orig');
SELECT pgit.commit('m base','app');
SELECT pgit.branch('cf');
UPDATE m SET v='main' WHERE id=1;
SELECT pgit.commit('m main','app');
SELECT pgit.checkout('cf');
UPDATE m SET v='feature' WHERE id=1;
SELECT pgit.commit('m feature','app');
SQL

"$PGIT" merge main >/dev/null 2>&1; rc=$?
is "AC-CLI-03: a conflicted merge exits non-zero" "$rc" "1"
like "AC-CLI-01: conflicts lists the unresolved row" "$("$PGIT" conflicts | head -1)" 'UNRESOLVED'

key=$(psql "$PGIT_DSN" -X -q -At -c "SELECT k FROM pgit.conflicts LIMIT 1")
"$PGIT" resolve m "$key" theirs >/dev/null
like "AC-CLI-01: conflicts shows the resolution" "$("$PGIT" conflicts | head -1)" 'resolved:theirs'
"$PGIT" merge --continue >/dev/null
is "AC-CLI-01: merge --continue applied the resolution" \
   "$(psql "$PGIT_DSN" -X -q -At -c "SELECT v FROM m WHERE id=1")" "main"

is "AC-CLI-01: fsck reports a clean repository" "$("$PGIT" fsck)" "ok: no problems found"
like "AC-CLI-01: log -n limits output" "$("$PGIT" log --oneline -n 1 | wc -l | tr -d ' ')" '^1$'
like "AC-CLI-01: reflog shows ref movements" "$("$PGIT" reflog | head -1)" '^[0-9a-f]{7} '

psql "$PGIT_DSN" -X -q -c "UPDATE m SET v='dirty' WHERE id=1" >/dev/null
like "AC-CLI-01: diff with no revisions shows the working tree" "$("$PGIT" diff | head -1)" 'UPDATE'
"$PGIT" diff --exit-code >/dev/null; rc=$?
is "AC-CLI-03: working tree diff --exit-code returns 1 when dirty" "$rc" "1"

"$PGIT" reset HEAD --hard >/dev/null
is "AC-CLI-01: reset --hard restored the working tree" \
   "$(psql "$PGIT_DSN" -X -q -At -c "SELECT v FROM m WHERE id=1")" "main"

like "AC-CLI-01: show accepts a revision expression" "$("$PGIT" show HEAD~1 | head -1)" 'INSERT|UPDATE|DELETE'

"$PGIT" notes add HEAD -m "checked against the ledger" >/dev/null
is "AC-CLI-01: notes show reads back what notes add wrote" \
   "$("$PGIT" notes show HEAD)" "checked against the ledger"
like "AC-CLI-01: notes list shows the note against a short sha" \
     "$("$PGIT" notes list | head -1)" '^[0-9a-f]{7}	checked against the ledger$'
"$PGIT" notes rm HEAD >/dev/null
"$PGIT" notes show HEAD >/dev/null 2>&1; rc=$?
is "AC-CLI-03: notes show exits 129 once the note is gone" "$rc" "129"
"$PGIT" notes add HEAD >/dev/null 2>&1; rc=$?
is "AC-CLI-03: notes add without -m exits 129" "$rc" "129"

like "AC-CLI-01: rerere status shows the resolution the earlier merge taught it" \
     "$("$PGIT" rerere status | head -1)" '^m	theirs	[0-9]+ use\(s\)$'
like "AC-CLI-01: rerere forget clears the recorded resolutions" \
     "$("$PGIT" rerere forget)" '^forgot 1 recorded resolution\(s\)$'
is "AC-CLI-01: rerere status is empty after forget" "$("$PGIT" rerere status)" ""

is "AC-CLI-01: renames reports nothing between two commits that renamed nothing" \
   "$("$PGIT" renames HEAD~1 HEAD)" ""
"$PGIT" renames HEAD >/dev/null 2>&1; rc=$?
is "AC-CLI-03: renames with one revision exits 129" "$rc" "129"
"$PGIT" notes list --graph >/dev/null 2>&1; rc=$?
is "AC-CLI-03: an unsupported flag on notes exits 129" "$rc" "129"

BR=$(psql "$PGIT_DSN" -X -q -At -c "SELECT pgit.head()")
psql "$PGIT_DSN" -X -q >/dev/null 2>&1 <<SQL
CREATE TABLE oct (id int PRIMARY KEY, v text);
SELECT pgit.track('oct');
INSERT INTO oct SELECT g, 'base' FROM generate_series(1,3) g;
SELECT pgit.commit('oct base','app');
SELECT pgit.branch('o1');
SELECT pgit.branch('o2');
SELECT pgit.checkout('o1');
UPDATE oct SET v='one' WHERE id=1;
SELECT pgit.commit('o1 edit','app');
SELECT pgit.checkout('o2');
UPDATE oct SET v='two' WHERE id=2;
SELECT pgit.commit('o2 edit','app');
SELECT pgit.checkout('$BR');
SQL

is "AC-CLI-01: merge with two branches runs an octopus merge" "$("$PGIT" merge o1 o2)" "merged o1 o2"
is "AC-CLI-01: both branches landed in one commit" \
   "$(psql "$PGIT_DSN" -X -q -At -c "SELECT string_agg(v,',' ORDER BY id) FROM oct")" "one,two,base"
is "AC-CLI-01: the octopus commit has three parents" \
   "$(psql "$PGIT_DSN" -X -q -At -c "SELECT count(*) FROM pgit.parents_of(pgit.resolve('$BR'))")" "3"
"$PGIT" merge o1 o2 -X ours >/dev/null 2>&1; rc=$?
is "AC-CLI-03: an octopus merge with a strategy option exits 129" "$rc" "129"

psql "$ADMIN" -X -q -c "DROP DATABASE pgit_cli" >/dev/null

suite_end CLI 40
