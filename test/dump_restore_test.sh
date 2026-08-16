#!/usr/bin/env bash
set -uo pipefail

ADMIN="${GROVE_ADMIN_DSN:-postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/postgres}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="grove_dump_src_$$"
DST="grove_dump_dst_$$"
CLONE="grove_dump_clone_$$"
H="${GROVE_HOST:-localhost:5460}"
S="postgresql://postgres:grove@$H/$SRC"
R="postgresql://postgres:grove@$H/$DST"
C="postgresql://postgres:grove@$H/$CLONE"
F="/tmp/grove_dump_$$.dump"
. "$(dirname "$0")/lib.sh"

cleanup() {
  for d in "$SRC" "$DST" "$CLONE"; do
    psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS $d WITH (FORCE)" >/dev/null 2>&1
  done
  rm -f "$F"
}
trap cleanup EXIT

for d in "$SRC" "$DST" "$CLONE"; do
  psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS $d" -c "CREATE DATABASE $d" >/dev/null 2>&1
done
psql "$S" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1
psql "$C" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1

psql "$S" -X -q >/dev/null 2>&1 <<'SQL'
CREATE TABLE t (id int PRIMARY KEY, v text);
CREATE TABLE u (id int PRIMARY KEY, w int);
SELECT grove.track('t');
SELECT grove.track('u');
INSERT INTO t SELECT g, 'v'||g FROM generate_series(1,200) g;
INSERT INTO u SELECT g, g*2 FROM generate_series(1,50) g;
SELECT grove.commit('base','alice');
UPDATE t SET v = 'changed' WHERE id = 1;
SELECT grove.commit('second','bob');
SELECT grove.branch('side');
SQL

BEFORE=$(psql "$S" -X -q -At -c "SELECT count(*)||'/'||(SELECT string_agg(tbl::text,',' ORDER BY tbl::text) FROM grove.tracked)||'/'||(SELECT count(*) FROM t) FROM grove.commits")

pg_dump "$S" -Fc -f "$F" >/dev/null 2>&1
is "dump: pg_dump produced an archive" "$([ -s "$F" ] && echo yes || echo no)" "yes"

OUT=$(pg_restore -d "$R" "$F" 2>&1)
is "dump: pg_restore reported no errors" "$(printf '%s' "$OUT" | grep -ci 'error')" "0"

q(){ psql "$R" -X -q -At -c "$1" 2>&1; }

is "dump: history, tracked tables and rows all came back" \
   "$(q "SELECT count(*)||'/'||(SELECT string_agg(tbl::text,',' ORDER BY tbl::text) FROM grove.tracked)||'/'||(SELECT count(*) FROM t) FROM grove.commits")" "$BEFORE"
is "dump: the tracked regclass columns still resolve, so the oids were dumped by name" \
   "$(q "SELECT string_agg(tbl::text,',' ORDER BY tbl::text) FROM grove.tracked")" "t,u"
is "dump: the journal triggers came across too" \
   "$(q "SELECT count(*) > 0 FROM pg_trigger WHERE tgname LIKE 'grove_journal%' AND NOT tgisinternal")" "t"
is "dump: the restored database is clean" "$(q 'SELECT count(*) FROM grove.fsck()')" "0"
is "dump: and reports nothing to commit, the table still matches its tree" "$(q 'SELECT grove.is_dirty()')" "f"

psql "$R" -X -q -c "UPDATE t SET v = 'after restore' WHERE id = 5" >/dev/null 2>&1
is "dump: a change made after the restore is journalled, so the triggers really fire" \
   "$(q 'SELECT count(*) FROM grove.changes WHERE commit_sha IS NULL')" "1"
is "dump: and it commits" "$(q "SELECT grove.commit('after restore','carol') IS NOT NULL")" "t"
is "dump: leaving the table matching the tree that commit recorded" \
   "$(q "SELECT grove.write_tree('t') = root_hash FROM grove.trees WHERE commit_sha = grove.resolve('main') AND tbl='t'")" "t"

is "dump: a branch made before the dump can still be checked out" \
   "$(q "SELECT grove.checkout('side', true) >= 0")" "t"
is "dump: and it puts the old value back" "$(q "SELECT v FROM t WHERE id = 5")" "v5"

psql "$R" -X -q -At -c "SELECT grove.bundle(ARRAY['main'])" > "/tmp/grove_dump_bundle_$$.json" 2>&1
{ echo "SET client_min_messages=warning;"
  printf '\\set b `cat /tmp/grove_dump_bundle_%s.json`\n' "$$"
  echo "SELECT grove.clone_from(:'b'::jsonb, 'main');"
} | psql "$C" -X -q -At >/dev/null 2>&1
rm -f "/tmp/grove_dump_bundle_$$.json"
is "dump: the restored database can still be cloned from" \
   "$(psql "$C" -X -q -At -c 'SELECT count(*) FROM t' 2>&1)" "200"

suite_end DUMP-RESTORE 13
