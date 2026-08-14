INSERT INTO bench_shas VALUES ('lr_base', pgit.resolve('main'))
ON CONFLICT (label) DO UPDATE SET sha = EXCLUDED.sha;

DO $$
DECLARE t0 timestamptz := clock_timestamp(); i int;
BEGIN
  FOR i IN 1..10000 LOOP
    UPDATE big SET hits = i WHERE id BETWEEN 300000 AND 300009;
    PERFORM pgit.commit('bump ' || i, 'bench');
  END LOOP;
  INSERT INTO bench_results VALUES ('commit_x10000_one_txn',
    extract(epoch FROM clock_timestamp() - t0) * 1000 / 10000,
    'mean ms per commit, 10000 commits in ONE transaction')
  ON CONFLICT (step) DO UPDATE SET ms = EXCLUDED.ms, detail = EXCLUDED.detail;
END $$;

INSERT INTO bench_shas VALUES ('lr_head', pgit.resolve('main'))
ON CONFLICT (label) DO UPDATE SET sha = EXCLUDED.sha;

DO $$
DECLARE t0 timestamptz := clock_timestamp(); n bigint;
BEGIN
  SELECT count(*) INTO n FROM pgit.diff(
    (SELECT sha FROM bench_shas WHERE label='lr_base'),
    (SELECT sha FROM bench_shas WHERE label='lr_head'));
  INSERT INTO bench_results VALUES ('diff_across_10000_commits',
    extract(epoch FROM clock_timestamp() - t0) * 1000,
    'AC-PERF-02: ' || n || ' rows differ, 10000 commits apart')
  ON CONFLICT (step) DO UPDATE SET ms = EXCLUDED.ms, detail = EXCLUDED.detail;
END $$;
