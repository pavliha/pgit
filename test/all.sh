#!/usr/bin/env bash
# Single entry point. Runs every suite, reports one total, exits non-zero if any
# suite fails OR is missing. A suite that cannot run is a failure, not a pass —
# silently skipping is how a green run comes to mean nothing.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
ONLY="${1:-}"
TOTAL=0
FAILED_SUITES=()
SKIPPED=()

run_suite() {
  local label="$1" script="$2"
  shift 2
  [ -n "$ONLY" ] && [[ "$label" != *"$ONLY"* ]] && return 0

  echo "=== $label"
  local out rc t0 t1
  t0=$(date +%s)
  out=$("$script" "$@" 2>&1); rc=$?
  t1=$(date +%s)
  printf '%s\n' "$out" | grep -E '^(not ok|# )' | head -20
  local line
  line=$(printf '%s\n' "$out" | grep -E '(GREEN|RED)' | tail -1)
  echo "    ${line:-no summary line — suite produced no verdict}   [$((t1-t0))s]"

  local n
  n=$(printf '%s' "$line" | grep -oE '\(([0-9]+) checks\)' | grep -oE '[0-9]+' || true)
  TOTAL=$((TOTAL + ${n:-0}))
  [ $rc -ne 0 ] && FAILED_SUITES+=("$label")
  return 0
}

run_suite "pgtap        " "$DIR/run.sh"
run_suite "cli          " "$DIR/cli_test.sh"
run_suite "crash-safety " "$DIR/kill_test.sh"
run_suite "non-superuser" "$DIR/rds_test.sh"
run_suite "remote       " "$DIR/remote_test.sh"

# The real-schema suite needs an application dump. It is opt-in by nature, so it
# is reported as skipped rather than silently omitted from the totals.
if [ -n "${DUMP:-}" ]; then
  run_suite "real-schema  " "$ROOT/bench/realworld_intoge.sh"
else
  SKIPPED+=("real-schema (set DUMP=/path/to/app.dump to include it)")
fi

echo
echo "─────────────────────────────────────────────"
for s in "${SKIPPED[@]:-}"; do [ -n "$s" ] && echo "skipped: $s"; done
if [ ${#FAILED_SUITES[@]} -eq 0 ]; then
  echo "ALL GREEN — $TOTAL checks"
  exit 0
fi
echo "FAILED: ${FAILED_SUITES[*]}"
echo "$TOTAL checks ran"
exit 1
