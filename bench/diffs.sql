DO $$
DECLARE t0 timestamptz; n bigint;
BEGIN
  t0 := clock_timestamp();
  SELECT count(*) INTO n FROM grove.diff(
    (SELECT sha FROM bench_shas WHERE label='after1000'),
    (SELECT sha FROM bench_shas WHERE label='after10'));
  INSERT INTO bench_results VALUES ('diff_10_rows_of_1m',
    extract(epoch FROM clock_timestamp() - t0) * 1000, 'AC-PERF-01 target < 100 ms, found ' || n || ' rows')
  ON CONFLICT (step) DO UPDATE SET ms = EXCLUDED.ms, detail = EXCLUDED.detail;
END $$;

DO $$
DECLARE t0 timestamptz; n bigint;
BEGIN
  t0 := clock_timestamp();
  SELECT count(*) INTO n FROM grove.diff(
    (SELECT sha FROM bench_shas WHERE label='base'),
    (SELECT sha FROM bench_shas WHERE label='after1000'));
  INSERT INTO bench_results VALUES ('diff_1000_rows_of_1m',
    extract(epoch FROM clock_timestamp() - t0) * 1000, 'found ' || n || ' rows')
  ON CONFLICT (step) DO UPDATE SET ms = EXCLUDED.ms, detail = EXCLUDED.detail;
END $$;

DO $$
DECLARE t0 timestamptz; n bigint;
BEGIN
  t0 := clock_timestamp();
  SELECT count(*) INTO n FROM grove.diff_stat(
    (SELECT sha FROM bench_shas WHERE label='after1000'),
    (SELECT sha FROM bench_shas WHERE label='after10'));
  INSERT INTO bench_results VALUES ('diff_stat_10_rows',
    extract(epoch FROM clock_timestamp() - t0) * 1000, 'stat over the same pair')
  ON CONFLICT (step) DO UPDATE SET ms = EXCLUDED.ms, detail = EXCLUDED.detail;
END $$;

DO $$
DECLARE t0 timestamptz; n bigint;
BEGIN
  t0 := clock_timestamp();
  SELECT count(*) INTO n FROM grove.blame('big', '700005');
  INSERT INTO bench_results VALUES ('blame_one_row',
    extract(epoch FROM clock_timestamp() - t0) * 1000, 'blame a single row, ' || n || ' columns')
  ON CONFLICT (step) DO UPDATE SET ms = EXCLUDED.ms, detail = EXCLUDED.detail;
END $$;
