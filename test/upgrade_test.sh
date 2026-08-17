#!/usr/bin/env bash
set -uo pipefail

ADMIN="${GROVE_ADMIN_DSN:-postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/postgres}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
DB="grove_upgrade_$$"
U="postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/$DB"
WR="grove_up_w_$$"
RO="grove_up_r_$$"
. "$(dirname "$0")/lib.sh"

cleanup() {
  psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" >/dev/null 2>&1
  psql "$ADMIN" -X -q -c "DROP ROLE IF EXISTS $WR" -c "DROP ROLE IF EXISTS $RO" >/dev/null 2>&1
}
trap cleanup EXIT

psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB" >/dev/null 2>&1
psql "$ADMIN" -X -q -c "DROP ROLE IF EXISTS $WR" -c "CREATE ROLE $WR LOGIN PASSWORD 'w'" \
                   -c "DROP ROLE IF EXISTS $RO" -c "CREATE ROLE $RO LOGIN PASSWORD 'r'" >/dev/null 2>&1
psql "$U" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1

psql "$U" -X -q >/dev/null 2>&1 <<SQL
CREATE TABLE t (id int PRIMARY KEY, v text);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'v'||g FROM generate_series(1,300) g;
SELECT grove.commit('base','alice');
UPDATE t SET v = 'changed' WHERE id = 1;
SELECT grove.commit('second','bob');
SELECT grove.tag('v1');
SELECT grove.grant_write('$WR');
SELECT grove.grant_read('$RO');
GRANT ALL ON t TO $WR;
SQL

q(){ psql "$U" -X -q -At -c "$1" 2>&1; }
execs(){ q "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname='grove' AND has_function_privilege('$1', p.oid, 'EXECUTE')"; }

BEFORE_W=$(execs "$WR")
BEFORE_R=$(execs "$RO")
BEFORE_STATE=$(q "SELECT count(*)||'/'||(SELECT count(*) FROM grove.nodes)||'/'||(SELECT count(*) FROM t) FROM grove.commits")

is "upgrade: install.sql drops and recreates some functions, so grants are really at risk" \
   "$(grep -c '^DROP FUNCTION IF EXISTS' "$DIR/sql/install.sql" | awk '{print ($1 > 0) ? "yes" : "no"}')" "yes"
is "upgrade: the write role starts with a meaningful number of functions" \
   "$(( BEFORE_W > 100 ? 1 : 0 ))" "1"

OUT=$(psql "$U" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" 2>&1)
is "upgrade: installing over an existing database succeeds" \
   "$(printf '%s' "$OUT" | grep -ci 'ERROR')" "0"

is "upgrade: history, nodes and rows all survive" "$(q "SELECT count(*)||'/'||(SELECT count(*) FROM grove.nodes)||'/'||(SELECT count(*) FROM t) FROM grove.commits")" "$BEFORE_STATE"
is "upgrade: fsck is clean afterwards" "$(q 'SELECT count(*) FROM grove.fsck()')" "0"
is "upgrade: the write role keeps every function it had" "$(execs "$WR")" "$BEFORE_W"
is "upgrade: the read role keeps every function it had" "$(execs "$RO")" "$BEFORE_R"
is "upgrade: the levels granted are recorded, which is how they are restored" \
   "$(q "SELECT count(*) FROM grove.access WHERE role_name IN ('$WR','$RO')")" "2"

is "upgrade: the write role can still commit, rather than failing inside commit on a dropped function" \
   "$(psql "postgresql://$WR:w@${GROVE_HOST:-localhost:5460}/$DB" -X -q -At \
        -c "INSERT INTO t VALUES (99999,'after upgrade')" \
        -c "SELECT grove.commit('after upgrade','w') IS NOT NULL" 2>&1 | tail -1)" "t"

is "upgrade: the read role is still barred from every write and admin verb" \
   "$(q "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname='grove'
           AND (p.proname = ANY (grove.write_verbs()) OR p.proname = ANY (grove.admin_only_verbs()))
           AND has_function_privilege('$RO', p.oid, 'EXECUTE')")" "0"

# The pre-packed refusal used to name grove.write_tree as the way out, but install.sql
# drops that function 100 lines before the check ran, so the instruction was
# unfollowable and the database was left half migrated. The guard runs before anything
# is dropped or altered now, which is what these two assertions pin.
psql "$U" -X -q -c "ALTER TABLE grove.nodes DROP CONSTRAINT IF EXISTS nodes_stored_or_delta" \
                -c "UPDATE grove.nodes SET keys = NULL WHERE entries IS NOT NULL" >/dev/null 2>&1

PRE=$(psql "$U" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" 2>&1)
like "upgrade: a pre-packed store is refused rather than silently half migrated" \
     "$PRE" "pre-packed format"

is "upgrade: and the refusal leaves the functions intact, so the database is still usable" \
   "$(q "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'grove' AND p.proname = 'write_tree'")" "1"

suite_end UPGRADE 12
