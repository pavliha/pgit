#!/usr/bin/env bash
set -uo pipefail
ADMIN="${GROVE_ADMIN_DSN:-postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/postgres}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"

for TARGET in "$@"; do
  DSN="postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/grove_cs"
  psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS grove_cs" -c "CREATE DATABASE grove_cs" >/dev/null
  psql "$DSN" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1
  psql "$DSN" -X -q -c "UPDATE grove.meta SET value='$TARGET' WHERE key='chunk_target'" >/dev/null

  psql "$DSN" -X -q -At <<EOF 2>&1 | grep -E "^r "
CREATE TABLE big (id int PRIMARY KEY, name text, hits int, note text);
INSERT INTO big SELECT g, 'row-'||g, g%1000, NULL FROM generate_series(1,1000000) g;
ANALYZE big;
SELECT grove.track('big');
CREATE TABLE res (k text, ms numeric);
CREATE TABLE shas (k text, v bytea);

DO \$\$
DECLARE t0 timestamptz; s bytea; i int; n bigint;
BEGIN
  t0 := clock_timestamp(); s := grove.commit('base','b');
  INSERT INTO res VALUES ('initial commit (full build)', extract(epoch FROM clock_timestamp()-t0)*1000);
  INSERT INTO shas VALUES ('a', s);

  UPDATE big SET hits=hits+1 WHERE id BETWEEN 500000 AND 500999;
  t0 := clock_timestamp(); s := grove.commit('k1000','b');
  INSERT INTO res VALUES ('commit 1000 rows', extract(epoch FROM clock_timestamp()-t0)*1000);
  INSERT INTO shas VALUES ('b', s);

  UPDATE big SET hits=hits+1 WHERE id BETWEEN 700000 AND 700009;
  t0 := clock_timestamp(); s := grove.commit('k10','b');
  INSERT INTO res VALUES ('commit 10 rows', extract(epoch FROM clock_timestamp()-t0)*1000);
  INSERT INTO shas VALUES ('c', s);

  t0 := clock_timestamp();
  SELECT count(*) INTO n FROM grove.diff((SELECT v FROM shas WHERE k='b'),(SELECT v FROM shas WHERE k='c'));
  INSERT INTO res VALUES ('diff 10 rows', extract(epoch FROM clock_timestamp()-t0)*1000);

  t0 := clock_timestamp();
  SELECT count(*) INTO n FROM grove.diff((SELECT v FROM shas WHERE k='a'),(SELECT v FROM shas WHERE k='b'));
  INSERT INTO res VALUES ('diff 1000 rows', extract(epoch FROM clock_timestamp()-t0)*1000);

  t0 := clock_timestamp();
  FOR i IN 1..200 LOOP
    UPDATE big SET hits=i WHERE id BETWEEN 300000 AND 300009;
    PERFORM grove.commit('x'||i,'b');
  END LOOP;
  INSERT INTO res VALUES ('mean per commit over 200', extract(epoch FROM clock_timestamp()-t0)*1000/200);

  t0 := clock_timestamp();
  SELECT count(*) INTO n FROM grove.diff((SELECT v FROM shas WHERE k='a'), grove.resolve('main'));
  INSERT INTO res VALUES ('diff across 200 commits', extract(epoch FROM clock_timestamp()-t0)*1000);
END \$\$;

SELECT 'r '||rpad(k,28)||lpad(round(ms)::text,7)||' ms' FROM res;
SELECT 'r '||rpad('node storage',28)||lpad(pg_size_pretty(pg_total_relation_size('grove.nodes')),10);
SELECT 'r '||rpad('node count',28)||lpad(count(*)::text,10) FROM grove.nodes;
SELECT 'r '||rpad('tree depth',28)||lpad(grove.node_level(root_hash)::text,10) FROM grove.trees WHERE commit_sha=grove.resolve('main') AND tbl='big';
EOF
  echo "=== chunk_target=$TARGET ==="
done
psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS grove_cs" >/dev/null
