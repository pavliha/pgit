#!/usr/bin/env bash
set -uo pipefail

A="${PGIT_ADMIN_DSN:-postgresql://postgres:pgit@${PGIT_HOST:-localhost:5460}/postgres}"
SDB="${SDB:-pgit_soak}"
D="postgresql://postgres:pgit@${PGIT_HOST:-localhost:5460}/$SDB"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMMITS="${COMMITS:-10000}"
ROWS="${ROWS:-50000}"
EVERY="${EVERY:-500}"

psql "$A" -X -q -c "DROP DATABASE IF EXISTS $SDB WITH (FORCE)" -c "CREATE DATABASE $SDB" >/dev/null
psql "$D" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1
psql "$D" -X -q -c "CREATE TABLE s (id int PRIMARY KEY, v text, n int)" \
             -c "INSERT INTO s SELECT g,'v'||g,0 FROM generate_series(1,$ROWS) g" >/dev/null
psql "$D" -X -q -At -c "SELECT pgit.track('s')" >/dev/null
psql "$D" -X -q -At -c "SELECT pgit.commit('soak base','main')" >/dev/null

echo "# soak: $COMMITS commits over $ROWS rows, invariant checked every $EVERY"
printf '# %-8s %-11s %-11s %-9s %s\n' commits "mean ms" "node store" "fsck" "tree matches rebuild"

violations=0
for start in $(seq 0 "$EVERY" $((COMMITS - 1))); do
  psql "$D" -X -q -At >/dev/null 2>&1 <<SQL
SET statement_timeout = 0;
DO \$\$
DECLARE i int;
BEGIN
  FOR i IN 1..$EVERY LOOP
    UPDATE s SET n = n + 1 WHERE id % 997 = (i % 997);
    PERFORM pgit.commit('soak ' || ($start + i), 'main');
  END LOOP;
END \$\$;
SQL

  T0=$(python3 -c 'import time;print(int(time.time()*1000))')
  psql "$D" -X -q -At -c "UPDATE s SET n = n + 1 WHERE id % 997 = 5" -c "SELECT pgit.commit('probe','main')" >/dev/null 2>&1
  T1=$(python3 -c 'import time;print(int(time.time()*1000))')

  SIZE=$(psql "$D" -X -At -c "SELECT pg_size_pretty(pg_total_relation_size('pgit.nodes'))")
  FSCK=$(psql "$D" -X -At -c "SELECT count(*) FROM pgit.fsck()")
  MATCH=$(psql "$D" -X -At -c "SELECT pgit.write_tree('s') = (SELECT root_hash FROM pgit.trees WHERE commit_sha = pgit.resolve('main') AND tbl = 's')")

  printf '  %-8s %-11s %-11s %-9s %s\n' "$((start + EVERY))" "$((T1 - T0))" "$SIZE" "$FSCK" "$MATCH"
  if [ "$FSCK" != "0" ] || [ "$MATCH" != "t" ]; then violations=$((violations + 1)); fi
done

echo
echo "# gc at the end"
B=$(psql "$D" -X -At -c "SELECT pg_total_relation_size('pgit.nodes')")
psql "$D" -X -q -At -c "SET statement_timeout=0" -c "SELECT pgit.repack()" >/dev/null
psql "$D" -X -q -c "VACUUM FULL pgit.nodes" >/dev/null
AF=$(psql "$D" -X -At -c "SELECT pg_total_relation_size('pgit.nodes')")
psql "$D" -X -At -c "SELECT '  store ' || pg_size_pretty($B::bigint) || ' -> ' || pg_size_pretty($AF::bigint) || ' (' || round(100 - ($AF::numeric / GREATEST($B,1) * 100)) || '% off)'"
psql "$D" -X -At -c "SELECT '  fsck after gc: ' || count(*) FROM pgit.fsck()"
psql "$D" -X -At -c "SELECT '  tree matches after gc: ' || (pgit.write_tree('s') = (SELECT root_hash FROM pgit.trees WHERE commit_sha = pgit.resolve('main') AND tbl = 's'))"

echo
if [ "$violations" -ne 0 ]; then
  echo "# soak FAILED: $violations checkpoint(s) broke an invariant"
  exit 1
fi
echo "# soak ok: $COMMITS commits, every checkpoint held the invariant"
