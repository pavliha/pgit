#!/usr/bin/env bash
set -uo pipefail

DSN="${PGIT_DSN:-postgresql://postgres:pgit@localhost:5460/pgit_test}"
DIR="$(dirname "$0")"
TOTAL_OK=0
TOTAL_BAD=0
FAILED=0

for f in "$DIR"/*.sql; do
  name=$(basename "$f")
  out=$(psql "$DSN" -X -q -v ON_ERROR_STOP=0 -P pager=off -At -f "$f" 2>&1)

  plan=$(printf '%s\n' "$out" | grep -oE '^1\.\.[0-9]+' | head -1 | cut -d. -f3)
  ran=$(printf '%s\n' "$out" | grep -cE '^(ok|not ok) ' || true)
  bad=$(printf '%s\n' "$out" | grep -cE '^not ok ' || true)
  errs=$(printf '%s\n' "$out" | grep -cE '^psql:.*ERROR:' || true)
  plan=${plan:-0}

  TOTAL_OK=$((TOTAL_OK + ran - bad))
  TOTAL_BAD=$((TOTAL_BAD + bad))

  status="ok"
  if [ "$bad" -gt 0 ]; then status="FAIL"; FAILED=1; fi
  if [ "$plan" -ne "$ran" ]; then status="INCOMPLETE ($ran/$plan ran)"; FAILED=1; fi
  if [ "$errs" -gt 0 ]; then status="$status +${errs} SQL ERRORS"; FAILED=1; fi

  printf '%-44s %s\n' "$name" "$status"

  if [ "$status" != "ok" ]; then
    printf '%s\n' "$out" | grep -E '^not ok |^psql:.*ERROR:' | head -8 | sed 's/^/    /'
  fi
done

echo
echo "passed: $TOTAL_OK   failed: $TOTAL_BAD"
[ $FAILED -eq 0 ] && echo "SUITE GREEN" || echo "SUITE RED"
exit $FAILED
