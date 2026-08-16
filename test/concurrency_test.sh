#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"

ADMIN="${GROVE_ADMIN_DSN:-postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/postgres}"
D="postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/grove_conc"
WRITERS="${CONC_WRITERS:-4}"
ROUNDS="${CONC_ROUNDS:-5}"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS grove_conc WITH (FORCE)" \
                -c "CREATE DATABASE grove_conc" >/dev/null
psql "$D" -X -q -v ON_ERROR_STOP=1 -f "$DIR/../sql/install.sql" >/dev/null 2>&1
psql "$D" -X -q -c "CREATE TABLE c1 (id int PRIMARY KEY, v text)" >/dev/null
psql "$D" -X -q -At -c "SELECT grove.track('c1')" >/dev/null
psql "$D" -X -q -c "INSERT INTO c1 SELECT g, 'v'||g FROM generate_series(1,4000) g" >/dev/null
psql "$D" -X -q -At -c "SELECT grove.commit('base','main')" >/dev/null

won=0
lost=0
for r in $(seq 1 "$ROUNDS"); do
  for w in $(seq 1 "$WRITERS"); do
    psql "$D" -X -q -At -c "
      BEGIN;
      UPDATE c1 SET v = 'r${r}w${w}' WHERE id = $((r * 10 + w));
      SELECT grove.commit('r${r}w${w}', 'main');
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

COMMITS=$(psql "$D" -X -At -c "SELECT count(*) FROM grove.commits")
REACH=$(psql "$D" -X -At -c "SELECT count(*) FROM grove.log(grove.resolve('main'))")
is "concurrency: history is linear, every commit reachable from the branch" "$REACH" "$COMMITS"

is "concurrency: the tree still matches a full rebuild" \
   "$(psql "$D" -X -At -c "SELECT grove.write_tree('c1') = (SELECT root_hash FROM grove.trees WHERE commit_sha = grove.resolve('main') AND tbl = 'c1')")" "t"

is "concurrency: fsck is clean afterwards" \
   "$(psql "$D" -X -At -c "SELECT count(*) FROM grove.fsck()")" "0"

is "concurrency: a rejected writer left no row behind" \
   "$(psql "$D" -X -At -c "SELECT count(*) FROM grove.changes WHERE commit_sha IS NULL")" "0"

suite_end CONCURRENCY 7
