#!/usr/bin/env bash
# Shared harness for the shell suites. Each one used to carry its own copy of
# these four functions and its own summary format; the totals in test/all.sh
# depend on every suite reporting the same way.
#
#   . "$(dirname "$0")/lib.sh"
#   is "what it checks" "$got" "$want"
#   suite_end RDS

PGIT_ADMIN_DSN="${PGIT_ADMIN_DSN:-postgresql://postgres:pgit@localhost:5460/postgres}"
PGIT_DSN="${PGIT_DSN:-postgresql://postgres:pgit@localhost:5460/pgit_test}"
PGIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

N=0
FAILED=0

ok()   { N=$((N+1)); printf 'ok %d - %s\n' "$N" "$1"; }
nok()  { N=$((N+1)); FAILED=$((FAILED+1)); printf 'not ok %d - %s\n' "$N" "$1"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1 (want '$3', got '$2')"; fi; }
isnt() { if [ "$2" != "$3" ]; then ok "$1"; else nok "$1 (did not want '$3')"; fi; }
like() { if [[ "$2" =~ $3 ]]; then ok "$1"; else nok "$1 (got '$2', wanted match $3)"; fi; }

# Refuse to report a green run that asserted nothing. A suite whose setup failed
# silently used to print "GREEN (0 checks)" and pass.
suite_end() {
  local name="$1" least="${2:-1}"
  echo
  if [ "$N" -lt "$least" ]; then
    echo "$name RED — only $N checks ran, expected at least $least"
    exit 1
  fi
  if [ "$FAILED" -eq 0 ]; then
    echo "$name GREEN ($N checks)"
    exit 0
  fi
  echo "$name RED ($FAILED of $N failed)"
  exit 1
}
