#!/usr/bin/env bash
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
  if [ $rc -ne 0 ]; then
    printf '%s\n' "$out" | grep -vE '^ok ' | sed 's/^/    | /'
  else
    printf '%s\n' "$out" | grep -E '^(not ok|# )' | head -20
  fi
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
run_suite "roundtrip    " "$DIR/roundtrip_test.sh"
run_suite "fuzz         " "$DIR/fuzz_test.sh"
run_suite "concurrency  " "$DIR/concurrency_test.sh"
run_suite "crash-fuzz   " "$DIR/crash_fuzz_test.sh"
run_suite "privileges   " "$DIR/privileges_test.sh"
run_suite "recovery     " "$DIR/recovery_test.sh"
run_suite "upgrade      " "$DIR/upgrade_test.sh"
run_suite "dump-restore " "$DIR/dump_restore_test.sh"
run_suite "ownership    " "$DIR/ownership_test.sh"

if [ -n "${DUMP:-}" ]; then
  run_suite "real-schema  " "$ROOT/bench/realworld_app.sh"
else
  SKIPPED+=("real-schema (set DUMP=/path/to/app.dump to include it)")
fi

BADGE=$(grep -oE 'tests-[0-9]+%20green' "$ROOT/README.md" | grep -oE '[0-9]+' | head -1)
TUNED="${FUZZ_ROUNDS:-}${FUZZ_OPS:-}${FUZZ_SEED:-}${FUZZ_ROWS:-}${FUZZ_CHUNK:-}"
if [ -n "$TUNED" ]; then
  SKIPPED+=("readme-badge (the fuzz settings were tuned, so the count is not the published one)")
elif [ -n "${DUMP:-}" ] && [ -n "$BADGE" ] && [ "$BADGE" != "$TOTAL" ]; then
  FAILED_SUITES+=("readme-badge (says $BADGE, suite runs $TOTAL)")
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
