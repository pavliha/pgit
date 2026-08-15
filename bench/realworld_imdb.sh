#!/usr/bin/env bash
set -uo pipefail

ADMIN="${PGIT_ADMIN_DSN:-postgresql://postgres:pgit@${PGIT_HOST:-localhost:5460}/postgres}"
DSN="${PGIT_IMDB_DSN:-postgresql://postgres:pgit@${PGIT_HOST:-localhost:5460}/pgit_imdb}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
DATA="${DATA:?set DATA to the directory holding the imdb tsv.gz files}"
NIGHTS="${NIGHTS:-30}"

q(){ psql "$DSN" -X -q -At -v ON_ERROR_STOP=1 -c "$1"; }
compact(){ psql "$DSN" -X -q -c "VACUUM FULL pgit.nodes" >/dev/null; }
sz(){ q "SELECT pg_size_pretty(pg_total_relation_size('$1'))"; }

psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS pgit_imdb" -c "CREATE DATABASE pgit_imdb" >/dev/null 2>&1
psql "$DSN" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null

q "CREATE TABLE title_basics (
     tconst text PRIMARY KEY, title_type text, primary_title text, original_title text,
     is_adult int, start_year int, end_year int, runtime_minutes int, genres text)" >/dev/null
q "CREATE TABLE title_ratings (
     tconst text PRIMARY KEY, average_rating numeric, num_votes int)" >/dev/null

COPYOPTS="WITH (FORMAT csv, DELIMITER E'\t', QUOTE E'\b', ESCAPE E'\b', NULL '\\N')"

echo "# loading imdb"
gzcat "$DATA/title.basics.tsv.gz"  | tail -n +2 | psql "$DSN" -X -q -c "COPY title_basics FROM STDIN $COPYOPTS"
gzcat "$DATA/title.ratings.tsv.gz" | tail -n +2 | psql "$DSN" -X -q -c "COPY title_ratings FROM STDIN $COPYOPTS"
q "ANALYZE title_basics" >/dev/null; q "ANALYZE title_ratings" >/dev/null

BROWS=$(q "SELECT count(*) FROM title_basics")
RROWS=$(q "SELECT count(*) FROM title_ratings")
echo "# title_basics $BROWS rows $(sz title_basics), title_ratings $RROWS rows $(sz title_ratings)"

q "SELECT pgit.track('title_basics')" >/dev/null
q "SELECT pgit.track('title_ratings')" >/dev/null

echo "# baseline commit"
q "DO \$\$
   DECLARE t0 timestamptz := clock_timestamp();
   BEGIN
     PERFORM pgit.commit('imdb baseline','imdb');
     RAISE NOTICE 'baseline commit % ms', round(extract(epoch FROM clock_timestamp()-t0)*1000);
   END \$\$" 2>&1 | sed 's/^NOTICE:  /# /'

q "CREATE TABLE bench_shas (label text PRIMARY KEY, sha bytea)" >/dev/null
q "INSERT INTO bench_shas VALUES ('night0', pgit.resolve('main'))" >/dev/null

compact
echo "# after baseline: nodes $(sz pgit.nodes) against $(q "SELECT pg_size_pretty((pg_total_relation_size('title_basics')+pg_total_relation_size('title_ratings'))::bigint)") of data"

echo "# $NIGHTS nightly ratings updates, weighted to popular titles like the real feed"
q "DO \$\$
   DECLARE t0 timestamptz; n int; touched bigint := 0; c bigint;
           commit_ms numeric := 0; update_ms numeric := 0;
   BEGIN
     FOR n IN 1..$NIGHTS LOOP
       t0 := clock_timestamp();
       WITH hot AS (
         SELECT tconst FROM title_ratings
         WHERE num_votes > 1000 AND ('x' || md5(tconst || n::text))::bit(32)::int % 20 = 0
       ), u AS (
         UPDATE title_ratings r
         SET num_votes = r.num_votes + 1 + (('x' || md5(r.tconst))::bit(32)::int % 50),
             average_rating = round(least(10.0, greatest(1.0,
               r.average_rating + ((('x' || md5(r.tconst || n::text))::bit(32)::int % 3) - 1) * 0.1)), 1)
         FROM hot WHERE r.tconst = hot.tconst RETURNING 1
       ) SELECT count(*) INTO c FROM u;
       touched := touched + c;
       update_ms := update_ms + extract(epoch FROM clock_timestamp()-t0)*1000;

       -- Only the commit is timed. The md5 scan and the UPDATE above are the
       -- fixture's own cost and were previously being charged to pgit.
       t0 := clock_timestamp();
       PERFORM pgit.commit('ratings night ' || n, 'imdb');
       commit_ms := commit_ms + extract(epoch FROM clock_timestamp()-t0)*1000;
     END LOOP;
     RAISE NOTICE '% rows over % nights: mean % ms per COMMIT, plus % ms of fixture work per night',
       touched, $NIGHTS, round(commit_ms/$NIGHTS), round(update_ms/$NIGHTS);
   END \$\$" 2>&1 | sed 's/^NOTICE:  /# /'

q "INSERT INTO bench_shas VALUES ('night_last', pgit.resolve('main'))" >/dev/null

q "DO \$\$
   DECLARE t0 timestamptz := clock_timestamp(); c bigint;
   BEGIN
     SELECT count(*) INTO c FROM pgit.diff(
       (SELECT sha FROM bench_shas WHERE label='night0'),
       (SELECT sha FROM bench_shas WHERE label='night_last'));
     RAISE NOTICE 'diff across all % nights: % rows in % ms',
       $NIGHTS, c, round(extract(epoch FROM clock_timestamp()-t0)*1000);
   END \$\$" 2>&1 | sed 's/^NOTICE:  /# /'

q "DO \$\$
   DECLARE t0 timestamptz := clock_timestamp(); c bigint;
   BEGIN
     SELECT count(*) INTO c FROM pgit.diff(
       (SELECT sha FROM bench_shas WHERE label='night_last'), pgit.resolve('main'), 'title_basics');
     RAISE NOTICE 'diff of the 12.7M row table nobody touched: % rows in % ms',
       c, round(extract(epoch FROM clock_timestamp()-t0)*1000);
   END \$\$" 2>&1 | sed 's/^NOTICE:  /# /'

compact
RAW=$(q "SELECT pg_total_relation_size('pgit.nodes')")
echo "# nodes before repack $(sz pgit.nodes)"

RP0=$(date +%s)
PACKED=$(q "SELECT pgit.repack()")
RP1=$(date +%s)
echo "# repack itself took $((RP1-RP0))s"
compact
B=$(q "SELECT pg_total_relation_size('pgit.nodes')")
echo "# nodes after repack at the default depth $(sz pgit.nodes) — $(q "SELECT round(100 - ($B::numeric / $RAW * 100))")% off, $PACKED packed"

echo "# fsck problems: $(q "SELECT count(*) FROM pgit.fsck()")"
echo "# every table still rebuilds to its recorded root: $(q "
  SELECT count(*) = 0 FROM pgit.tracked t
  JOIN pgit.trees r ON r.tbl = t.tbl::text AND r.commit_sha = pgit.resolve('main')
  WHERE pgit.write_tree(t.tbl) IS DISTINCT FROM r.root_hash")"
