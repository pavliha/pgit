#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"

ADMIN="${PGIT_ADMIN_DSN:-postgresql://postgres:pgit@${PGIT_HOST:-localhost:5460}/postgres}"
D="postgresql://postgres:pgit@${PGIT_HOST:-localhost:5460}/pgit_conc"
WRITERS="${CONC_WRITERS:-4}"
ROUNDS="${CONC_ROUNDS:-5}"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS pgit_conc WITH (FORCE)" \
                -c "CREATE DATABASE pgit_conc" >/dev/null
psql "$D" -X -q -v ON_ERROR_STOP=1 -f "$DIR/../sql/install.sql" >/dev/null 2>&1
psql "$D" -X -q -c "CREATE TABLE c1 (id int PRIMARY KEY, v text)" >/dev/null
psql "$D" -X -q -At -c "SELECT pgit.track('c1')" >/dev/null
psql "$D" -X -q -c "INSERT INTO c1 SELECT g, 'v'||g FROM generate_series(1,4000) g" >/dev/null
psql "$D" -X -q -At -c "SELECT pgit.commit('base','main')" >/dev/null

won=0
lost=0
for r in $(seq 1 "$ROUNDS"); do
  for w in $(seq 1 "$WRITERS"); do
    psql "$D" -X -q -At -c "
      BEGIN;
      UPDATE c1 SET v = 'r${r}w${w}' WHERE id = $((r * 10 + w));
      SELECT pgit.commit('r${r}w${w}', 'main');
      COMMIT;" > "$OUT/r${r}w${w}.log" 2>&1 &
  done
  wait
  for w in $(seq 1 "$WRITERS"); do
    if grep -qi "error" "$OUT/r${r}w${w}.log"; then lost=$((lost + 1)); else won=$((won + 1)); fi
  done
done

cmp_ok() { if [ "$1" -gt 0 ]; then ok "$2"; else nok "$2 (got $1)"; fi; }

cmp_ok "$won"  "concurrency: at least one writer committed in every round ($won of $((won+lost)) succeeded)"
cmp_ok "$lost" "concurrency: losers were rejected rather than silently dropped ($lost rejected)"

is "concurrency: every rejection names the ref that moved" \
   "$(cat "$OUT"/*.log | grep -ci 'moved under us')" "$lost"

COMMITS=$(psql "$D" -X -At -c "SELECT count(*) FROM pgit.commits")
REACH=$(psql "$D" -X -At -c "SELECT count(*) FROM pgit.log(pgit.resolve('main'))")
is "concurrency: history is linear, every commit reachable from the branch" "$REACH" "$COMMITS"

is "concurrency: the tree still matches a full rebuild" \
   "$(psql "$D" -X -At -c "SELECT pgit.write_tree('c1') = (SELECT root_hash FROM pgit.trees WHERE commit_sha = pgit.resolve('main') AND tbl = 'c1')")" "t"

is "concurrency: fsck is clean afterwards" \
   "$(psql "$D" -X -At -c "SELECT count(*) FROM pgit.fsck()")" "0"

is "concurrency: a rejected writer left no row behind" \
   "$(psql "$D" -X -At -c "SELECT count(*) FROM pgit.changes WHERE commit_sha IS NULL")" "0"

suite_end CONCURRENCY 7
