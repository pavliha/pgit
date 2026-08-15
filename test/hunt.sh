#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="${HUNT_LOG:-/tmp/pgit-hunt.log}"
BATCHES="${HUNT_BATCHES:-6}"

echo "# pgit hunt started $(date -u +%FT%TZ), $BATCHES batches" | tee -a "$LOG"

found=0
batch=0

for ops in 400 900; do
  for rows in 2500 12000; do
    for chunk in 8 32 64; do
      batch=$((batch + 1))
      [ "$batch" -gt "$BATCHES" ] && break 3

      out=$(FUZZ_OPS=$ops FUZZ_ROWS=$rows FUZZ_CHUNK=$chunk FUZZ_ROUNDS=2 \
            "$DIR/fuzz_test.sh" 2>&1)

      if printf '%s' "$out" | grep -q "not ok"; then
        found=$((found + 1))
        {
          echo "=== FAILURE  ops=$ops rows=$rows chunk=$chunk  $(date -u +%FT%TZ)"
          printf '%s\n' "$out" | grep -E "not ok|ERROR|replay with" | head -6
        } | tee -a "$LOG"
      else
        echo "ok  ops=$ops rows=$rows chunk=$chunk  $(printf '%s' "$out" | grep -oE '[0-9]+ checks')" | tee -a "$LOG"
      fi
    done
  done
done

echo "# hunt finished $(date -u +%FT%TZ), $found failing configuration(s)" | tee -a "$LOG"
exit 0
