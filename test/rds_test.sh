#!/usr/bin/env bash
set -uo pipefail

ADMIN="${PGIT_ADMIN_DSN:-postgresql://postgres:pgit@localhost:5460/postgres}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
U="postgresql://pgit_app:app@localhost:5460/pgit_rds"
. "$(dirname "$0")/lib.sh"
q()   { psql "$U" -X -q -At -c "$1" 2>&1; }

psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS pgit_rds" >/dev/null 2>&1
psql "$ADMIN" -X -q -c "DROP ROLE IF EXISTS pgit_app" >/dev/null 2>&1
psql "$ADMIN" -X -q -c "CREATE ROLE pgit_app LOGIN PASSWORD 'app'" \
                 -c "CREATE DATABASE pgit_rds OWNER pgit_app" >/dev/null

is "AC-PORT-02: the role has no superuser rights" \
   "$(psql "$ADMIN" -X -q -At -c "SELECT rolsuper FROM pg_roles WHERE rolname='pgit_app'")" "f"

if psql "$U" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1; then
  ok "AC-PORT-02: pgit installs as a non-superuser"
else
  nok "AC-PORT-02: pgit installs as a non-superuser"
fi

psql "$U" -X -q >/dev/null 2>&1 <<'SQL'
CREATE TABLE side (id serial PRIMARY KEY, op text);
CREATE TABLE cats (id int PRIMARY KEY, name text);
CREATE TABLE t (id int PRIMARY KEY, name text, cat int NOT NULL REFERENCES cats(id));
CREATE FUNCTION note() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN INSERT INTO side(op) VALUES (TG_OP); RETURN NULL; END $f$;
CREATE TRIGGER user_side AFTER INSERT OR UPDATE OR DELETE ON t
  FOR EACH ROW EXECUTE FUNCTION note();
INSERT INTO cats VALUES (1,'a'),(2,'b');
SELECT pgit.track('t');
INSERT INTO t SELECT g, 'row-'||g, 1 FROM generate_series(1,300) g;
SELECT pgit.commit('base','app');
SELECT pgit.branch('feature');
UPDATE t SET name='changed' WHERE id=5;
SELECT pgit.commit('edit','app');
DELETE FROM side;
SQL

is "AC-PORT-02: revert works without superuser" "$(q "SELECT pgit.revert(pgit.resolve('main'))")" "1"
is "AC-PORT-02: revert restored the value"      "$(q "SELECT name FROM t WHERE id=5")" "row-5"
is "AC-REPLAY-01: no user trigger fired during replay" "$(q "SELECT count(*) FROM side")" "0"
is "AC-PORT-02: the user trigger was restored to its original state" \
   "$(q "SELECT tgenabled::text FROM pg_trigger WHERE tgname='user_side'")" "O"

q "SELECT pgit.commit('revert commit','app')" >/dev/null
is "AC-PORT-02: checkout works without superuser" "$(q "SELECT pgit.checkout('feature')")" "0"
is "AC-PORT-02: merge works without superuser"    "$(q "SELECT pgit.merge('main')")" "0"
is "AC-PORT-02: repack works without superuser"   "$(q "SELECT pgit.repack() >= 0")" "t"
is "AC-PORT-02: blame works without superuser"    "$(q "SELECT count(*) > 0 FROM pgit.blame('t','5')")" "t"
is "AC-PORT-02: the tree still matches a full rebuild" \
   "$(q "SELECT pgit.write_tree('t') = (SELECT root_hash FROM pgit.trees WHERE commit_sha=pgit.resolve(pgit.head()) AND tbl='t')")" "t"

is "AC-PORT-02: foreign keys stay enforced on the fallback replay path" \
   "$(q "INSERT INTO t VALUES (9999,'x',42)" | grep -c 'violates foreign key')" "1"

psql "$ADMIN" -X -q -c "DROP DATABASE pgit_rds" -c "DROP ROLE pgit_app" >/dev/null

suite_end RDS 12
