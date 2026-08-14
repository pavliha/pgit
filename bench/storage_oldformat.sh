#!/usr/bin/env bash
set -uo pipefail

DSN="${PGIT_DSN:-postgresql://postgres:pgit@localhost:5460/pgit_test}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
q(){ psql "$DSN" -X -q -At -v ON_ERROR_STOP=1 -c "$1"; }
bytes(){ q "SELECT pg_total_relation_size('pgit.nodes')"; }
compact(){ psql "$DSN" -X -q -v ON_ERROR_STOP=1 -c "VACUUM FULL pgit.nodes" >/dev/null; }

difftime(){
  q "DO \$\$
     DECLARE t0 timestamptz := clock_timestamp();
     BEGIN
       PERFORM count(*) FROM pgit.diff(
         (SELECT sha FROM bench_shas WHERE label='s_base'),
         (SELECT sha FROM bench_shas WHERE label='s_head'));
       INSERT INTO bench_results VALUES ('tmp_diff',
         extract(epoch FROM clock_timestamp() - t0) * 1000, '')
       ON CONFLICT (step) DO UPDATE SET ms = EXCLUDED.ms;
     END \$\$" >/dev/null
  q "SELECT round(ms) FROM bench_results WHERE step='tmp_diff'"
}

q "SELECT pgit.unpack()" >/dev/null
compact
RAW=$(bytes)
TBL=$(q "SELECT pg_total_relation_size('big')")

q "CREATE OR REPLACE FUNCTION pgit.make_delta(base jsonb, target jsonb) RETURNS jsonb
   LANGUAGE plpgsql IMMUTABLE AS \$f\$
   DECLARE a text := base::text; b text := target::text; p int; sfx int;
   BEGIN
     p := pgit.common_prefix(a, b);
     sfx := pgit.common_suffix(a, b, least(length(a), length(b)) - p);
     RETURN jsonb_build_object('p', p, 's', sfx, 'm', substr(b, p + 1, length(b) - p - sfx));
   END \$f\$" >/dev/null

echo "one splice format, same fixture"
for d in 4 16 50; do
  q "SELECT pgit.unpack()" >/dev/null
  compact
  PACKED=$(q "SELECT pgit.repack($d)")
  compact
  B=$(bytes)
  printf 'nodes, repack depth %-3s %s   %sx the table   %s%% off   diff %s ms   (%s packed)\n' \
    "$d" "$(q "SELECT pg_size_pretty($B::bigint)")" \
    "$(q "SELECT round($B::numeric / $TBL, 1)")" \
    "$(q "SELECT round(100 - ($B::numeric / $RAW * 100))")" \
    "$(difftime)" "$PACKED"
done

psql "$DSN" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null
echo "restored the op list format"
