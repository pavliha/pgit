#!/usr/bin/env bash
set -uo pipefail

ADMIN="${GROVE_ADMIN_DSN:-postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/postgres}"
export GROVE_DSN="${GROVE_CLI_DSN:-postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/grove_cli}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
GROVE="$DIR/bin/grove"
. "$(dirname "$0")/lib.sh"

psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS grove_cli" -c "CREATE DATABASE grove_cli" >/dev/null
psql "$GROVE_DSN" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null
psql "$GROVE_DSN" -X -q -c "CREATE TABLE t (id int PRIMARY KEY, name text, hits int)" \
                  -c "INSERT INTO t SELECT g, 'row-'||g, 0 FROM generate_series(1,20) g" >/dev/null

"$GROVE" track t >/dev/null
out=$("$GROVE" commit -m "base")
like "AC-CLI-01: commit prints a git shaped line" "$out" '^\[main [0-9a-f]{7}\] base$'

A=$(psql "$GROVE_DSN" -X -q -At -c "SELECT encode(grove.resolve('main'),'hex')")

is "AC-CLI-01: status reports a clean tree" "$("$GROVE" status | tail -1)" "nothing to commit, working tree clean"

like "AC-CLI-01: log --oneline starts with a seven character sha" \
     "$("$GROVE" log --oneline | head -1)" '^[0-9a-f]{7} base$'

"$GROVE" log --graph >/dev/null 2>/tmp/grove_err; rc=$?
is "AC-CLI-02: an unimplemented flag exits 129" "$rc" "129"
like "AC-CLI-02: the error names the flag rather than ignoring it" "$(cat /tmp/grove_err)" 'unsupported flag --graph'

"$GROVE" frobnicate >/dev/null 2>/tmp/grove_err; rc=$?
is "AC-CLI-02: an unknown command exits 129" "$rc" "129"
like "AC-CLI-02: the error names the command" "$(cat /tmp/grove_err)" "'frobnicate' is not a grove command"

"$GROVE" commit >/dev/null 2>/tmp/grove_err; rc=$?
is "AC-CLI-02: commit without -m is refused" "$rc" "129"

psql "$GROVE_DSN" -X -q -c "UPDATE t SET hits = 1 WHERE id <= 3" >/dev/null
"$GROVE" commit -m "touch three rows" >/dev/null
B=$(psql "$GROVE_DSN" -X -q -At -c "SELECT encode(grove.resolve('main'),'hex')")

"$GROVE" diff "$A" "$B" --exit-code >/dev/null; rc=$?
is "AC-CLI-03: diff --exit-code returns 1 when there are differences" "$rc" "1"

"$GROVE" diff "$B" "$B" --exit-code >/dev/null; rc=$?
is "AC-CLI-03: diff --exit-code returns 0 when there are none" "$rc" "0"

line=$("$GROVE" diff "$A" "$B" --numstat | head -1)
is "AC-CLI-04: numstat is three tab separated fields" "$(printf '%s' "$line" | awk -F'\t' '{print NF}')" "3"
is "AC-CLI-04: numstat reports three changed rows" "$(printf '%s' "$line" | cut -f1)" "3"

is "AC-CLI-01: name-status marks the table as modified" \
   "$("$GROVE" diff "$A" "$B" --name-status | head -1 | cut -f1)" "M"

"$GROVE" branch feature >/dev/null
like "AC-CLI-01: branch marks the checked out branch with an asterisk" \
     "$("$GROVE" branch | tr '\n' ' ')" '\* main'

is "AC-CLI-01: blame names the author of a column" \
   "$("$GROVE" blame t 1 | head -1 | grep -c 'hits')" "1"

psql "$GROVE_DSN" -X -q >/dev/null 2>&1 <<'SQL'
CREATE TABLE m (id int PRIMARY KEY, v text);
SELECT grove.track('m');
INSERT INTO m VALUES (1,'orig');
SELECT grove.commit('m base','app');
SELECT grove.branch('cf');
UPDATE m SET v='main' WHERE id=1;
SELECT grove.commit('m main','app');
SELECT grove.checkout('cf');
UPDATE m SET v='feature' WHERE id=1;
SELECT grove.commit('m feature','app');
SQL

"$GROVE" merge main >/dev/null 2>&1; rc=$?
is "AC-CLI-03: a conflicted merge exits non-zero" "$rc" "1"
like "AC-CLI-01: conflicts lists the unresolved row" "$("$GROVE" conflicts | head -1)" 'UNRESOLVED'

key=$(psql "$GROVE_DSN" -X -q -At -c "SELECT k FROM grove.conflicts LIMIT 1")
"$GROVE" resolve m "$key" theirs >/dev/null
like "AC-CLI-01: conflicts shows the resolution" "$("$GROVE" conflicts | head -1)" 'resolved:theirs'
"$GROVE" merge --continue >/dev/null
is "AC-CLI-01: merge --continue applied the resolution" \
   "$(psql "$GROVE_DSN" -X -q -At -c "SELECT v FROM m WHERE id=1")" "main"

is "AC-CLI-01: fsck reports a clean repository" "$("$GROVE" fsck)" "ok: no problems found"
like "AC-CLI-01: log -n limits output" "$("$GROVE" log --oneline -n 1 | wc -l | tr -d ' ')" '^1$'
like "AC-CLI-01: reflog shows ref movements" "$("$GROVE" reflog | head -1)" '^[0-9a-f]{7} '

psql "$GROVE_DSN" -X -q -c "UPDATE m SET v='dirty' WHERE id=1" >/dev/null
like "AC-CLI-01: diff with no revisions shows the working tree" "$("$GROVE" diff | head -1)" 'UPDATE'
"$GROVE" diff --exit-code >/dev/null; rc=$?
is "AC-CLI-03: working tree diff --exit-code returns 1 when dirty" "$rc" "1"

"$GROVE" reset HEAD --hard >/dev/null
is "AC-CLI-01: reset --hard restored the working tree" \
   "$(psql "$GROVE_DSN" -X -q -At -c "SELECT v FROM m WHERE id=1")" "main"

like "AC-CLI-01: show accepts a revision expression" "$("$GROVE" show HEAD~1 | head -1)" 'INSERT|UPDATE|DELETE'

"$GROVE" notes add HEAD -m "checked against the ledger" >/dev/null
is "AC-CLI-01: notes show reads back what notes add wrote" \
   "$("$GROVE" notes show HEAD)" "checked against the ledger"
like "AC-CLI-01: notes list shows the note against a short sha" \
     "$("$GROVE" notes list | head -1)" '^[0-9a-f]{7}	checked against the ledger$'
"$GROVE" notes rm HEAD >/dev/null
"$GROVE" notes show HEAD >/dev/null 2>&1; rc=$?
is "AC-CLI-03: notes show exits 129 once the note is gone" "$rc" "129"
"$GROVE" notes add HEAD >/dev/null 2>&1; rc=$?
is "AC-CLI-03: notes add without -m exits 129" "$rc" "129"

like "AC-CLI-01: rerere status shows the resolution the earlier merge taught it" \
     "$("$GROVE" rerere status | head -1)" '^m	theirs	[0-9]+ use\(s\)$'
like "AC-CLI-01: rerere forget clears the recorded resolutions" \
     "$("$GROVE" rerere forget)" '^forgot 1 recorded resolution\(s\)$'
is "AC-CLI-01: rerere status is empty after forget" "$("$GROVE" rerere status)" ""

is "AC-CLI-01: renames reports nothing between two commits that renamed nothing" \
   "$("$GROVE" renames HEAD~1 HEAD)" ""
"$GROVE" renames HEAD >/dev/null 2>&1; rc=$?
is "AC-CLI-03: renames with one revision exits 129" "$rc" "129"
"$GROVE" notes list --graph >/dev/null 2>&1; rc=$?
is "AC-CLI-03: an unsupported flag on notes exits 129" "$rc" "129"

BR=$(psql "$GROVE_DSN" -X -q -At -c "SELECT grove.head()")
psql "$GROVE_DSN" -X -q >/dev/null 2>&1 <<SQL
CREATE TABLE oct (id int PRIMARY KEY, v text);
SELECT grove.track('oct');
INSERT INTO oct SELECT g, 'base' FROM generate_series(1,3) g;
SELECT grove.commit('oct base','app');
SELECT grove.branch('o1');
SELECT grove.branch('o2');
SELECT grove.checkout('o1');
UPDATE oct SET v='one' WHERE id=1;
SELECT grove.commit('o1 edit','app');
SELECT grove.checkout('o2');
UPDATE oct SET v='two' WHERE id=2;
SELECT grove.commit('o2 edit','app');
SELECT grove.checkout('$BR');
SQL

is "AC-CLI-01: merge with two branches runs an octopus merge" "$("$GROVE" merge o1 o2)" "merged o1 o2"
is "AC-CLI-01: both branches landed in one commit" \
   "$(psql "$GROVE_DSN" -X -q -At -c "SELECT string_agg(v,',' ORDER BY id) FROM oct")" "one,two,base"
is "AC-CLI-01: the octopus commit has three parents" \
   "$(psql "$GROVE_DSN" -X -q -At -c "SELECT count(*) FROM grove.parents_of(grove.resolve('$BR'))")" "3"
"$GROVE" merge o1 o2 -X ours >/dev/null 2>&1; rc=$?
is "AC-CLI-03: an octopus merge with a strategy option exits 129" "$rc" "129"

help=$("$GROVE" help); rc=$?
is "AC-CLI-05: help exits 0" "$rc" "0"
"$GROVE" >/dev/null 2>&1; rc=$?
is "AC-CLI-05: no arguments exits 129" "$rc" "129"

undocumented=$(comm -23 \
  <(sed -n '/^case "\$cmd" in$/,$p' "$GROVE" | grep -oE '^[a-z|-]+\)' | tr -d ')' | tr '|' '\n' | sort -u) \
  <(printf '%s\n' "$help" | grep -oE '^   [a-z-]+' | tr -d ' ' | sort -u))
is "AC-CLI-05: every command appears in help" "$undocumented" ""

psql "$ADMIN" -X -q -c "DROP DATABASE grove_cli" >/dev/null

suite_end CLI 43
