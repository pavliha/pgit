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

SRCDB="grove_conc_src_$$"
psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS $SRCDB" -c "CREATE DATABASE $SRCDB" >/dev/null 2>&1
SRC="postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/$SRCDB"
psql "$SRC" -X -q -v ON_ERROR_STOP=1 -f "$DIR/../sql/install.sql" >/dev/null 2>&1
psql "$SRC" -X -q >/dev/null 2>&1 <<'SQL'
CREATE TABLE c1 (id int PRIMARY KEY, v text);
SELECT grove.track('c1');
INSERT INTO c1 SELECT g, 'v'||g FROM generate_series(1,100) g;
SELECT grove.commit('shared base','alice');
SQL
psql "$SRC" -X -q -At -c "SELECT grove.bundle(ARRAY['main'])" > "/tmp/grove_conc_base_$$.json" 2>&1

RDB="grove_conc_recv_$$"
psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS $RDB" -c "CREATE DATABASE $RDB" >/dev/null 2>&1
R="postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/$RDB"
psql "$R" -X -q -v ON_ERROR_STOP=1 -f "$DIR/../sql/install.sql" >/dev/null 2>&1
{ echo "SET client_min_messages=warning;"
  printf '\\set b `cat /tmp/grove_conc_base_%s.json`\n' "$$"
  echo "SELECT grove.clone_from(:'b'::jsonb,'main');"
} | psql "$R" -X -q -At >/dev/null 2>&1

psql "$SRC" -X -q >/dev/null 2>&1 <<'SQL'
UPDATE c1 SET v = 'from origin' WHERE id = 1;
SELECT grove.commit('origin moves ahead','alice');
SQL
psql "$SRC" -X -q -At -c "SELECT grove.bundle(ARRAY['main'])" > "/tmp/grove_conc_ahead_$$.json" 2>&1

RECV_OUT=$(mktemp); COMMIT_OUT=$(mktemp)
lost=0; rounds=0; rejected=0

for attempt in 1 2 3 4 5; do
  psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS $RDB WITH (FORCE)" -c "CREATE DATABASE $RDB" >/dev/null 2>&1
  psql "$R" -X -q -v ON_ERROR_STOP=1 -f "$DIR/../sql/install.sql" >/dev/null 2>&1
  { echo "SET client_min_messages=warning;"
    printf '\\set b `cat /tmp/grove_conc_base_%s.json`\n' "$$"
    echo "SELECT grove.clone_from(:'b'::jsonb,'main');"
  } | psql "$R" -X -q -At >/dev/null 2>&1

  { { echo "SET client_min_messages=warning;"
      printf '\\set b `cat /tmp/grove_conc_ahead_%s.json`\n' "$$"
      echo "BEGIN; SELECT pg_sleep(1); SELECT grove.receive(:'b'::jsonb); COMMIT;"
    } | psql "$R" -X -q -At > "$RECV_OUT" 2>&1; } &
  { psql "$R" -X -q -At -c "BEGIN" -c "UPDATE c1 SET v='local work' WHERE id=2" \
         -c "SELECT pg_sleep(1)" -c "SELECT grove.commit('local commit','bob')" -c "COMMIT" \
         > "$COMMIT_OUT" 2>&1; } &
  wait

  rounds=$((rounds + 1))
  if grep -qi error "$COMMIT_OUT"; then
    rejected=$((rejected + 1))
  else
    reach=$(psql "$R" -X -q -At -c "SELECT count(*) FROM grove.ancestors(grove.resolve('main')) a JOIN grove.commits c ON c.sha = a.a WHERE c.message = 'local commit'")
    [ "$reach" = "1" ] || lost=$((lost + 1))
  fi
done

is "concurrency: a commit that reported success is never discarded by a racing receive" "$lost" "0"
cmp_ok "$rounds" "concurrency: the race actually ran ($rounds rounds, $rejected of them rejecting one side)"

is "concurrency: the store is clean after a receive raced a commit" \
   "$(psql "$R" -X -q -At -c 'SELECT count(*) FROM grove.fsck()')" "0"
is "concurrency: and the loser left nothing pending behind it" \
   "$(psql "$R" -X -q -At -c 'SELECT count(*) FROM grove.changes WHERE commit_sha IS NULL')" "0"

rm -f "$RECV_OUT" "$COMMIT_OUT" "/tmp/grove_conc_base_$$.json" "/tmp/grove_conc_ahead_$$.json"
psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS $SRCDB WITH (FORCE)" -c "DROP DATABASE IF EXISTS $RDB WITH (FORCE)" >/dev/null 2>&1

suite_end CONCURRENCY 11
