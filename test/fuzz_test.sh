#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"

OPS="${FUZZ_OPS:-150}"
ROWS="${FUZZ_ROWS:-400}"
CHUNK="${FUZZ_CHUNK:-8}"
SEED="${FUZZ_SEED:-}"
ROUNDS="${FUZZ_ROUNDS:-3}"

ADMIN="${PGIT_ADMIN_DSN:-postgresql://postgres:pgit@${PGIT_HOST:-localhost:5460}/postgres}"

survived=0
for round in $(seq 1 "$ROUNDS"); do
  if [ -n "$SEED" ]; then s="$SEED"; else s="0.$(( (RANDOM * 32768 + RANDOM) % 1000000 ))"; fi

  psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS pgit_fuzz WITH (FORCE)" \
                  -c "CREATE DATABASE pgit_fuzz" >/dev/null
  D="postgresql://postgres:pgit@${PGIT_HOST:-localhost:5460}/pgit_fuzz"
  psql "$D" -X -q -v ON_ERROR_STOP=1 -f "$DIR/../sql/install.sql" >/dev/null 2>&1

  out=$(psql "$D" -X -q -At -v ops="$OPS" -v seed="$s" -v rows="$ROWS" -v chunk="$CHUNK" -f "$DIR/fuzz/fuzz.sql" 2>&1)

  if echo "$out" | grep -q "every tree matched a rebuild"; then
    survived=$((survived + OPS))
    ok "fuzz: $OPS random operations on seed $s held every invariant"
  else
    nok "fuzz: seed $s violated an invariant"
    echo "$out" | grep -iE "ERROR|fuzz:" | head -3
    echo "  replay with: FUZZ_SEED=$s FUZZ_ROUNDS=1 FUZZ_OPS=$OPS ./test/fuzz_test.sh"
    psql "$D" -X -F' | ' -A -c \
      "SELECT n, op, left(detail,60) FROM fuzz_log ORDER BY n DESC LIMIT 8" 2>/dev/null
  fi
done

ok "fuzz: $survived operations survived across $ROUNDS seeds with no invariant violation"

suite_end FUZZ 2
