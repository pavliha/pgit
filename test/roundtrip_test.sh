#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"

ADMIN="${GROVE_ADMIN_DSN:-postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/postgres}"
SRC="postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/grove_rt_src"
DST="postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/grove_rt_dst"
OPS="${RT_OPS:-120}"
ROWS="${RT_ROWS:-600}"
CHUNK="${RT_CHUNK:-8}"
ROUNDS="${RT_ROUNDS:-3}"
PACK="$(mktemp)"

cleanup() {
  rm -f "$PACK"
  psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS grove_rt_src WITH (FORCE)" \
                  -c "DROP DATABASE IF EXISTS grove_rt_dst WITH (FORCE)" >/dev/null 2>&1
}
trap cleanup EXIT

for round in $(seq 1 "$ROUNDS"); do
  s="0.$(( (RANDOM * 32768 + RANDOM) % 1000000 ))"

  psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS grove_rt_src WITH (FORCE)" \
                  -c "CREATE DATABASE grove_rt_src" >/dev/null 2>&1
  psql "$SRC" -X -q -v ON_ERROR_STOP=1 -f "$DIR/../sql/install.sql" >/dev/null 2>&1

  if ! psql "$SRC" -X -q -At -v ops="$OPS" -v seed="$s" -v rows="$ROWS" -v chunk="$CHUNK" \
        -f "$DIR/fuzz/fuzz.sql" >/dev/null 2>&1; then
    nok "roundtrip: seed $s did not survive its own fuzz run, cannot test the bundle"
    continue
  fi

  psql "$SRC" -X -At -c "SELECT grove.bundle(ARRAY['main'])" > "$PACK" 2>/dev/null
  if [ ! -s "$PACK" ]; then
    nok "roundtrip: seed $s produced no bundle"
    continue
  fi

  psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS grove_rt_dst WITH (FORCE)" \
                  -c "CREATE DATABASE grove_rt_dst" >/dev/null 2>&1
  psql "$DST" -X -q -v ON_ERROR_STOP=1 -f "$DIR/../sql/install.sql" >/dev/null 2>&1

  out=$( { printf '\\set b `cat %s`\n' "$PACK"
           echo "SELECT grove.clone_from(:'b'::jsonb, 'main');"
         } | psql "$DST" -X -q -At 2>&1 )
  if printf '%s' "$out" | grep -qiE "error|too long|cannot"; then
    nok "roundtrip: seed $s failed to clone ($(printf '%s' "$out" | grep -i error | head -1))"
    continue
  fi

  src_roots=$(psql "$SRC" -X -At -c "
    SELECT string_agg(t.tbl || '=' || encode(t.root_hash,'hex'), ',' ORDER BY t.tbl)
    FROM grove.trees t WHERE t.commit_sha = grove.resolve('main')")
  dst_roots=$(psql "$DST" -X -At -c "
    SELECT string_agg(t.tbl || '=' || encode(t.root_hash,'hex'), ',' ORDER BY t.tbl)
    FROM grove.trees t WHERE t.commit_sha = grove.resolve('main')")

  is "roundtrip: seed $s clones to bit identical roots" "$dst_roots" "$src_roots"

  dst_live=$(psql "$DST" -X -At -c "
    SELECT count(*) FROM grove.trees t
    WHERE t.commit_sha = grove.resolve('main')
      AND grove.write_tree(t.tbl::regclass) IS DISTINCT FROM t.root_hash")
  is "roundtrip: seed $s materialises tables that rebuild to the cloned roots" "$dst_live" "0"

  is "roundtrip: seed $s clone is fsck clean" \
     "$(psql "$DST" -X -At -c 'SELECT count(*) FROM grove.fsck()')" "0"
done

suite_end ROUNDTRIP $((ROUNDS * 3))
