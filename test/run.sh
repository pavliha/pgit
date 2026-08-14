#!/usr/bin/env bash
set -uo pipefail

ADMIN="${PGIT_ADMIN_DSN:-postgresql://postgres:pgit@localhost:5460/postgres}"
DIR="$(cd "$(dirname "$0")" && pwd)"

# Every other suite builds its own database; this one used to run against
# whatever pgit_test happened to hold. A leftover benchmark fixture — a tracked
# 1M row table with 10,000 commits — turned a single merge into 25 minutes,
# because merge covers every tracked table. Results must not depend on history.
if [ -z "${PGIT_DSN:-}" ]; then
  DSN="postgresql://postgres:pgit@localhost:5460/pgit_pgtap"
  psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS pgit_pgtap" -c "CREATE DATABASE pgit_pgtap" >/dev/null
  psql "$DSN" -X -q -v ON_ERROR_STOP=1 -f "$DIR/../sql/install.sql" >/dev/null
  psql "$DSN" -X -q -c "CREATE EXTENSION IF NOT EXISTS pgtap" >/dev/null
  OWNED=1
else
  DSN="$PGIT_DSN"
  OWNED=0
fi
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

[ "$OWNED" = 1 ] && psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS pgit_pgtap" >/dev/null

echo
if [ "$TOTAL_OK" -lt 300 ]; then
  echo "PGTAP RED — only $TOTAL_OK assertions ran, the suite is far smaller than expected"
  exit 1
fi
[ $FAILED -eq 0 ] && echo "PGTAP GREEN ($TOTAL_OK checks)" || echo "PGTAP RED ($TOTAL_BAD of $((TOTAL_OK + TOTAL_BAD)) failed)"
exit $FAILED
