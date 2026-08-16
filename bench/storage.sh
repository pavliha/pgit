#!/usr/bin/env bash
set -uo pipefail

DSN="${GROVE_DSN:-postgresql://postgres:grove@${GROVE_HOST:-localhost:5460}/grove_test}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMMITS="${COMMITS:-10000}"
q(){ psql "$DSN" -X -q -At -v ON_ERROR_STOP=1 -c "$1"; }

size(){ q "SELECT pg_size_pretty(pg_total_relation_size('grove.nodes'))"; }
bytes(){ q "SELECT pg_total_relation_size('grove.nodes')"; }
tblbytes(){ q "SELECT pg_total_relation_size('big')"; }

compact(){ psql "$DSN" -X -q -v ON_ERROR_STOP=1 -c "VACUUM FULL grove.nodes" >/dev/null; }

difftime(){
  q "DO \$\$
     DECLARE t0 timestamptz := clock_timestamp(); n bigint;
     BEGIN
       SELECT count(*) INTO n FROM grove.diff(
         (SELECT sha FROM bench_shas WHERE label='s_base'),
         (SELECT sha FROM bench_shas WHERE label='s_head'));
       RAISE NOTICE 'rows %', n;
       INSERT INTO bench_results VALUES ('tmp_diff',
         extract(epoch FROM clock_timestamp() - t0) * 1000, '')
       ON CONFLICT (step) DO UPDATE SET ms = EXCLUDED.ms;
     END \$\$" >/dev/null
  q "SELECT round(ms) FROM bench_results WHERE step='tmp_diff'"
}

echo "building the 1M row fixture"
psql "$DSN" -X -q -v ON_ERROR_STOP=1 -f "$DIR/bench/fixture.sql" >/dev/null
q "CREATE TABLE IF NOT EXISTS bench_shas (label text PRIMARY KEY, sha bytea)" >/dev/null
q "SELECT grove.commit('storage base','bench')" >/dev/null
q "INSERT INTO bench_shas VALUES ('s_base', grove.resolve('main'))
   ON CONFLICT (label) DO UPDATE SET sha = EXCLUDED.sha" >/dev/null

echo "running $COMMITS commits in one transaction"
q "DO \$\$
   DECLARE i int;
   BEGIN
     FOR i IN 1..$COMMITS LOOP
       UPDATE big SET hits = i WHERE id BETWEEN 300000 AND 300009;
       PERFORM grove.commit('bump ' || i, 'bench');
     END LOOP;
   END \$\$" >/dev/null
q "INSERT INTO bench_shas VALUES ('s_head', grove.resolve('main'))
   ON CONFLICT (label) DO UPDATE SET sha = EXCLUDED.sha" >/dev/null

compact
TBL=$(tblbytes)
RAW=$(bytes)
printf '\ntable                 %s\n' "$(q "SELECT pg_size_pretty($TBL::bigint)")"
printf 'nodes, no repack      %s   %sx the table   diff %s ms\n' \
  "$(q "SELECT pg_size_pretty($RAW::bigint)")" \
  "$(q "SELECT round($RAW::numeric / $TBL, 1)")" "$(difftime)"

for d in 4 16 50 200; do
  q "SELECT grove.unpack()" >/dev/null
  compact
  PACKED=$(q "SELECT grove.repack($d)")
  compact
  B=$(bytes)
  printf 'nodes, repack depth %-3s %s   %sx the table   %s%% off   diff %s ms   (%s packed)\n' \
    "$d" "$(q "SELECT pg_size_pretty($B::bigint)")" \
    "$(q "SELECT round($B::numeric / $TBL, 1)")" \
    "$(q "SELECT round(100 - ($B::numeric / $RAW * 100))")" \
    "$(difftime)" "$PACKED"
done

q "DROP TABLE IF EXISTS bench_shas" >/dev/null
q "DELETE FROM bench_results WHERE step='tmp_diff'" >/dev/null
