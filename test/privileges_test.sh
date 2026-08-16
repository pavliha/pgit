#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"

ADMIN="${GROVE_ADMIN_DSN:-postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/postgres}"
D="postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/grove_priv"
H="${GROVE_HOST:-localhost:5460}"

cleanup() {
  psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS grove_priv WITH (FORCE)" >/dev/null 2>&1
  psql "$ADMIN" -X -q -c "DROP ROLE IF EXISTS grove_t_rdr" -c "DROP ROLE IF EXISTS grove_t_wtr" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

psql "$ADMIN" -X -q -c "CREATE DATABASE grove_priv" >/dev/null
psql "$ADMIN" -X -q -c "CREATE ROLE grove_t_rdr LOGIN PASSWORD 'x'" \
                -c "CREATE ROLE grove_t_wtr LOGIN PASSWORD 'x'" >/dev/null
psql "$D" -X -q -v ON_ERROR_STOP=1 -f "$DIR/../sql/install.sql" >/dev/null 2>&1
psql "$D" -X -q -c "CREATE TABLE t (id int PRIMARY KEY, v text)" \
             -c "INSERT INTO t SELECT g,'v'||g FROM generate_series(1,200) g" \
             -c "GRANT SELECT,INSERT,UPDATE,DELETE ON t TO grove_t_rdr, grove_t_wtr" >/dev/null
psql "$D" -X -q -At -c "SELECT grove.track('t')" >/dev/null
psql "$D" -X -q -At -c "SELECT grove.commit('base','main')" >/dev/null

R="postgresql://grove_t_rdr:x@$H/grove_priv"
W="postgresql://grove_t_wtr:x@$H/grove_priv"

is "privileges: nothing in grove is reachable by PUBLIC before a grant" \
   "$(psql "$D" -X -At -c "SELECT has_schema_privilege('public','grove','USAGE')")" "f"

RN=$(psql "$D" -X -At -c "SELECT grove.grant_read('grove_t_rdr')")
WN=$(psql "$D" -X -At -c "SELECT grove.grant_write('grove_t_wtr')")

cmp_lt() { if [ "$1" -lt "$2" ]; then ok "$3"; else nok "$3 (got $1 vs $2)"; fi; }
cmp_lt "$RN" "$WN" "privileges: read grants fewer functions than write ($RN against $WN)"

is "privileges: a reader can read history" \
   "$(psql "$R" -X -At -c "SELECT count(*) FROM grove.log(grove.resolve('main'))" 2>&1 | tail -1)" "1"

like "privileges: a reader cannot commit" \
   "$(psql "$R" -X -At -c "SELECT grove.commit('sneaky','main')" 2>&1 | tail -1)" "permission denied"

like "privileges: a reader cannot prune history" \
   "$(psql "$R" -X -At -c "SELECT grove.prune(now())" 2>&1 | tail -1)" "permission denied"

like "privileges: a reader cannot track a new table" \
   "$(psql "$R" -X -At -c "SELECT grove.track('t')" 2>&1 | tail -1)" "permission denied"

psql "$W" -X -q -c "UPDATE t SET v='by writer' WHERE id=1" >/dev/null 2>&1
is "privileges: a writer can commit" \
   "$(psql "$W" -X -At -c "SELECT (grove.commit('by writer','main') IS NOT NULL)" 2>&1 | tail -1)" "t"

like "privileges: a writer still cannot prune history" \
   "$(psql "$W" -X -At -c "SELECT grove.prune(now())" 2>&1 | tail -1)" "permission denied"

like "privileges: a writer cannot unbundle from an untrusted source" \
   "$(psql "$W" -X -At -c "SELECT grove.unbundle('{}'::jsonb)" 2>&1 | tail -1)" "permission denied"

is "privileges: granting a level to a role that does not exist is refused" \
   "$(psql "$D" -X -At -c "SELECT grove.grant_read('nobody_here')" 2>&1 | grep -c 'does not exist')" "1"

suite_end PRIVILEGES 10
