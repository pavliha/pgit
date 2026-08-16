#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"

OPS="${FUZZ_OPS:-150}"
ROWS="${FUZZ_ROWS:-400}"
CHUNK="${FUZZ_CHUNK:-8}"
SEED="${FUZZ_SEED:-}"
ROUNDS="${FUZZ_ROUNDS:-3}"

REGRESSION_SEEDS="0.772185 0.775743 0.319870"


ADMIN="${GROVE_ADMIN_DSN:-postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/postgres}"
FDB="grove_fuzz_$$"
trap 'psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS $FDB WITH (FORCE)" >/dev/null 2>&1' EXIT

seeds=()
if [ -n "$SEED" ]; then
  for round in $(seq 1 "$ROUNDS"); do seeds+=("$SEED"); done
else
  for known in $REGRESSION_SEEDS; do seeds+=("$known"); done
  for round in $(seq 1 "$ROUNDS"); do
    seeds+=("0.$(( (RANDOM * 32768 + RANDOM) % 1000000 ))")
  done
fi

survived=0
for s in "${seeds[@]}"; do

  D="postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/$FDB"
  prepare() {
    psql "$ADMIN" -X -q -v ON_ERROR_STOP=1 \
      -c "DROP DATABASE IF EXISTS $FDB WITH (FORCE)" \
      -c "CREATE DATABASE $FDB" 2>&1 || return 1
    psql "$D" -X -q -v ON_ERROR_STOP=1 -f "$DIR/../sql/install.sql" 2>&1 || return 1
  }
  if ! prep=$(prepare); then
    nok "fuzz: could not build a database for seed $s"
    printf '# %s\n' "$(printf '%s' "$prep" | grep -iE 'error|fatal' | head -2)"
    continue
  fi

  out=$(psql "$D" -X -q -At -v ops="$OPS" -v seed="$s" -v rows="$ROWS" -v chunk="$CHUNK" -f "$DIR/fuzz/fuzz.sql" 2>&1)
  rc=$?

  if [ $rc -eq 0 ] && echo "$out" | grep -q "every tree matched a rebuild"; then
    survived=$((survived + OPS))
    ok "fuzz: $OPS random operations on seed $s held every invariant"
    continue
  fi

  if echo "$out" | grep -qE "ERROR:  fuzz: op "; then
    nok "fuzz: seed $s violated an invariant"
  else
    nok "fuzz: seed $s did not finish, so no invariant was proved either way"
  fi
  printf '%s\n' "$out" | grep -iE "ERROR|FATAL|fuzz:" | head -3 | sed 's/^/# /'
  printf '# replay with: FUZZ_SEED=%s FUZZ_ROUNDS=1 FUZZ_OPS=%s ./test/fuzz_test.sh\n' "$s" "$OPS"
  psql "$D" -X -F' | ' -A -c \
    "SELECT n, op, left(detail,60) FROM fuzz_log ORDER BY n DESC LIMIT 8" 2>/dev/null | sed 's/^/# /'
done

ok "fuzz: $survived operations survived across ${#seeds[@]} seeds with no invariant violation"

suite_end FUZZ 2
