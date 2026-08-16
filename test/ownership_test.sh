#!/usr/bin/env bash
set -uo pipefail

ADMIN="${GROVE_ADMIN_DSN:-postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/postgres}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
H="${GROVE_HOST:-localhost:5460}"
DB="grove_owner_$$"
APP="grove_owner_app_$$"
O="postgresql://postgres:grove@$H/$DB"
A="postgresql://$APP:a@$H/$DB"
. "$(dirname "$0")/lib.sh"

cleanup() {
  psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" >/dev/null 2>&1
  psql "$ADMIN" -X -q -c "DROP ROLE IF EXISTS $APP" >/dev/null 2>&1
}
trap cleanup EXIT

psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS $DB" -c "DROP ROLE IF EXISTS $APP" \
                 -c "CREATE ROLE $APP LOGIN PASSWORD 'a'" -c "CREATE DATABASE $DB" >/dev/null 2>&1
psql "$O" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1
psql "$O" -X -q >/dev/null 2>&1 <<SQL
CREATE TABLE t (id int PRIMARY KEY, v text);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'v'||g FROM generate_series(1,100) g;
SELECT grove.commit('base','postgres');
SELECT grove.branch('side');
SELECT grove.grant_write('$APP');
GRANT ALL ON t TO $APP;
SQL

is "ownership: the app role is not the owner of the table" \
   "$(psql "$O" -X -q -At -c "SELECT pg_get_userbyid(relowner) = '$APP' FROM pg_class WHERE relname='t'")" "f"
is "ownership: and it is not a superuser either" \
   "$(psql "$O" -X -q -At -c "SELECT rolsuper FROM pg_roles WHERE rolname = '$APP'")" "f"

is "ownership: a non-owner write role can commit" \
   "$(psql "$A" -X -q -At -c "UPDATE t SET v='by app' WHERE id = 1" \
        -c "SELECT grove.commit('from the app role','app') IS NOT NULL" 2>&1 | tail -1)" "t"
is "ownership: and can check out while the table has no triggers of its own" \
   "$(psql "$A" -X -q -At -c "SELECT grove.checkout('side', true) >= 0" 2>&1 | tail -1)" "t"
psql "$O" -X -q -c "SELECT grove.checkout('main', true)" >/dev/null 2>&1

psql "$O" -X -q >/dev/null 2>&1 <<'SQL'
CREATE FUNCTION bump() RETURNS trigger LANGUAGE plpgsql AS $f$ BEGIN RETURN NEW; END $f$;
CREATE TRIGGER app_trigger BEFORE UPDATE ON t FOR EACH ROW EXECUTE FUNCTION bump();
SQL

is "ownership: the owner can still check out with a trigger present" \
   "$(psql "$O" -X -q -At -c "SELECT grove.checkout('side', true) >= 0" 2>&1 | tail -1)" "t"
psql "$O" -X -q -c "SELECT grove.checkout('main', true)" >/dev/null 2>&1

OUT=$(psql "$A" -X -q -At -c "SELECT grove.checkout('side', true)" 2>&1)
is "ownership: a non-owner cannot, and grove says why rather than leaving a bare owner error" \
   "$(printf '%s' "$OUT" | grep -c 'cannot pause trigger app_trigger')" "1"
is "ownership: the hint points at running as the owner or a superuser" \
   "$(printf '%s' "$OUT" | grep -c 'ownership of the table')" "1"
is "ownership: and nothing was half applied, the trigger is still enabled" \
   "$(psql "$O" -X -q -At -c "SELECT tgenabled FROM pg_trigger WHERE tgname = 'app_trigger'")" "O"

suite_end OWNERSHIP 8
