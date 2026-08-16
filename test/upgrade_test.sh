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

suite_end UPGRADE 10
