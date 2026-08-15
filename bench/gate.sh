#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
RUNS="${GATE_RUNS:-5}"

if [ "$RUNS" -lt 3 ]; then
  echo "gate: refusing to judge performance on $RUNS run(s); a single run is not a measurement" >&2
  exit 2
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for i in $(seq 1 "$RUNS"); do
  "$DIR/quick.sh" 2>/dev/null | grep -oE "^[a-z0-9 ,~]+ +[0-9]+ms" >> "$TMP/raw"
done

median() {
  grep -F "$1" "$TMP/raw" | grep -oE "[0-9]+ms" | tr -d 'ms' | sort -n \
    | awk '{a[NR]=$1} END {if (NR) print a[int((NR+1)/2)]}'
}
spread() {
  grep -F "$1" "$TMP/raw" | grep -oE "[0-9]+ms" | tr -d 'ms' | sort -n \
    | awk '{a[NR]=$1} END {if (NR) printf "%d-%d", a[1], a[NR]}'
}

fail=0
check() {
  local label="$1" ceiling="$2" med sp
  med=$(median "$label")
  sp=$(spread "$label")
  if [ -z "$med" ]; then
    printf '  %-26s no reading\n' "$label"
    fail=1
    return
  fi
  if [ "$med" -gt "$ceiling" ]; then
    printf '  %-26s %6sms  (range %s)  OVER the %sms ceiling\n' "$label" "$med" "$sp" "$ceiling"
    fail=1
  else
    printf '  %-26s %6sms  (range %s)  ceiling %sms\n' "$label" "$med" "$sp" "$ceiling"
  fi
}

echo "medians of $RUNS runs, 200k rows:"

check "full build, 200000 rows" 3000
check "mean of 20 more commits" 900
check "diff across 20 commits"  2200
check "~2000 scattered rows"    1800

if [ "$fail" -ne 0 ]; then
  echo
  echo "gate: FAILED - a measurement is over its ceiling"
  exit 1
fi

echo
echo "gate: ok"
