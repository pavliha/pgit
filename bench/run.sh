#!/usr/bin/env bash
set -euo pipefail

ADMIN="${PGIT_ADMIN_DSN:-postgresql://postgres:pgit@${PGIT_HOST:-localhost:5460}/postgres}"
DSN="${PGIT_BENCH_DSN:-postgresql://postgres:pgit@${PGIT_HOST:-localhost:5460}/pgit_bench}"
DIR="$(dirname "$0")"

psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS pgit_bench" -c "CREATE DATABASE pgit_bench"
psql "$DSN" -X -q -v ON_ERROR_STOP=1 -f "$DIR/../sql/install.sql"

for f in fixture commits diffs longrange ddl; do
  echo "── $f"
  psql "$DSN" -X -q -v ON_ERROR_STOP=1 -f "$DIR/$f.sql"
done

psql "$DSN" -X -q -At -c \
  "SELECT rpad(step,24)||' '||lpad(round(ms)::text,7)||' ms   '||detail FROM bench_results ORDER BY step"
psql "$DSN" -X -q -At -c \
  "SELECT 'node storage '||pg_size_pretty(pg_total_relation_size('pgit.nodes'))||' for a '||pg_size_pretty(pg_total_relation_size('big'))||' table'"

psql "$ADMIN" -X -q -c "DROP DATABASE pgit_bench"
