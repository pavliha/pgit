#!/usr/bin/env bash
set -uo pipefail
A="${PGIT_ADMIN_DSN:-postgresql://postgres:pgit@localhost:5460/postgres}"
D="postgresql://postgres:pgit@localhost:5460/pgit_quick"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROWS="${ROWS:-200000}"
NIGHTS="${NIGHTS:-20}"

psql "$A" -X -q -c "DROP DATABASE IF EXISTS pgit_quick" -c "CREATE DATABASE pgit_quick" >/dev/null 2>&1
psql "$D" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" 2>/dev/null >/dev/null

psql "$D" -X -q -At <<SQL 2>&1 | grep WARNING | sed 's/^WARNING:  //'
CREATE TABLE r (tconst text PRIMARY KEY, average_rating numeric, num_votes int, note text);
INSERT INTO r SELECT 'tt' || lpad(g::text,8,'0'), 5.0, g, NULL FROM generate_series(1,$ROWS) g;
ANALYZE r;
SELECT pgit.track('r');
CREATE TABLE shas (label text PRIMARY KEY, sha bytea);
DO \$\$
DECLARE t0 timestamptz; n int; cm numeric := 0; c bigint;
BEGIN
  t0 := clock_timestamp(); PERFORM pgit.commit('base','p');
  RAISE WARNING 'full build, $ROWS rows      %ms', round(extract(epoch FROM clock_timestamp()-t0)*1000);
  INSERT INTO shas VALUES ('a', pgit.resolve('main'));

  UPDATE r SET num_votes = num_votes + 1 WHERE tconst BETWEEN 'tt00050000' AND 'tt00050099';
  t0 := clock_timestamp(); PERFORM pgit.commit('adj','p');
  RAISE WARNING '100 adjacent rows          %ms', round(extract(epoch FROM clock_timestamp()-t0)*1000);

  UPDATE r SET num_votes = num_votes + 1 WHERE ('x'||md5(tconst))::bit(32)::int % 100 = 0;
  t0 := clock_timestamp(); PERFORM pgit.commit('sc','p');
  RAISE WARNING '~$((ROWS/100)) scattered rows        %ms', round(extract(epoch FROM clock_timestamp()-t0)*1000);

  FOR n IN 1..$NIGHTS LOOP
    UPDATE r SET num_votes = num_votes + 7 WHERE ('x'||md5(tconst||n::text))::bit(32)::int % 200 = 0;
    t0 := clock_timestamp(); PERFORM pgit.commit('night '||n,'p');
    cm := cm + extract(epoch FROM clock_timestamp()-t0)*1000;
  END LOOP;
  RAISE WARNING 'mean of $NIGHTS more commits   %ms', round(cm/$NIGHTS);
  INSERT INTO shas VALUES ('b', pgit.resolve('main'));

  t0 := clock_timestamp();
  SELECT count(*) INTO c FROM pgit.diff((SELECT sha FROM shas WHERE label='a'),(SELECT sha FROM shas WHERE label='b'));
  RAISE WARNING 'diff across $NIGHTS commits    %ms for % rows', round(extract(epoch FROM clock_timestamp()-t0)*1000), c;

  RAISE WARNING 'tree matches full rebuild  %',
    (pgit.write_tree('r') = (SELECT root_hash FROM pgit.trees WHERE commit_sha=pgit.resolve('main') AND tbl='r'));
END \$\$;
SQL
psql "$D" -X -q -c "VACUUM FULL pgit.nodes" >/dev/null
RAW=$(psql "$D" -X -q -At -c "SELECT pg_total_relation_size('pgit.nodes')")
if [ "${GC:-0}" != "1" ]; then
  echo "node store                 $(psql "$D" -X -q -At -c "SELECT pg_size_pretty($RAW::bigint)") against $(psql "$D" -X -q -At -c "SELECT pg_size_pretty(pg_total_relation_size('r'))") of data"
  echo "fsck problems              $(psql "$D" -X -q -At -c "SELECT count(*) FROM pgit.fsck()")"
  echo "(GC=1 to also measure repack, which is slow)"
  exit 0
fi
echo "node store                 $(psql "$D" -X -q -At -c "SELECT pg_size_pretty($RAW::bigint)") against $(psql "$D" -X -q -At -c "SELECT pg_size_pretty(pg_total_relation_size('r'))") of data"
T0=$(date +%s); P=$(psql "$D" -X -q -At -c "SELECT pgit.repack()"); T1=$(date +%s)
psql "$D" -X -q -c "VACUUM FULL pgit.nodes" >/dev/null
B=$(psql "$D" -X -q -At -c "SELECT pg_total_relation_size('pgit.nodes')")
echo "after gc                   $(psql "$D" -X -q -At -c "SELECT pg_size_pretty($B::bigint)") — $(psql "$D" -X -q -At -c "SELECT round(100 - ($B::numeric/$RAW*100))")% off, $P packed, $((T1-T0))s"
echo "fsck problems              $(psql "$D" -X -q -At -c "SELECT count(*) FROM pgit.fsck()")"
