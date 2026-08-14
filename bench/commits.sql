CREATE TABLE IF NOT EXISTS bench_shas (label text PRIMARY KEY, sha bytea);

DO $$
DECLARE t0 timestamptz := clock_timestamp(); s bytea;
BEGIN
  s := pgit.commit('base', 'bench');
  INSERT INTO bench_shas VALUES ('base', s) ON CONFLICT (label) DO UPDATE SET sha = EXCLUDED.sha;
  INSERT INTO bench_results VALUES ('commit_initial_1m',
    extract(epoch FROM clock_timestamp() - t0) * 1000, 'first commit, full tree build over 1M rows')
  ON CONFLICT (step) DO UPDATE SET ms = EXCLUDED.ms;
END $$;

DO $$
DECLARE t0 timestamptz; s bytea;
BEGIN
  UPDATE big SET hits = hits + 1 WHERE id BETWEEN 500000 AND 500999;
  t0 := clock_timestamp();
  s := pgit.commit('touch 1000 rows', 'bench');
  INSERT INTO bench_shas VALUES ('after1000', s) ON CONFLICT (label) DO UPDATE SET sha = EXCLUDED.sha;
  INSERT INTO bench_results VALUES ('commit_1000_rows',
    extract(epoch FROM clock_timestamp() - t0) * 1000, 'AC-PERF-04 target < 1000 ms')
  ON CONFLICT (step) DO UPDATE SET ms = EXCLUDED.ms;
END $$;

DO $$
DECLARE t0 timestamptz; s bytea;
BEGIN
  UPDATE big SET hits = hits + 1 WHERE id BETWEEN 700000 AND 700009;
  t0 := clock_timestamp();
  s := pgit.commit('touch 10 rows', 'bench');
  INSERT INTO bench_shas VALUES ('after10', s) ON CONFLICT (label) DO UPDATE SET sha = EXCLUDED.sha;
  INSERT INTO bench_results VALUES ('commit_10_rows',
    extract(epoch FROM clock_timestamp() - t0) * 1000, 'commit touching 10 rows')
  ON CONFLICT (step) DO UPDATE SET ms = EXCLUDED.ms;
END $$;
