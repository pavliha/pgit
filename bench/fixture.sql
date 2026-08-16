CREATE TABLE IF NOT EXISTS bench_results (step text PRIMARY KEY, ms numeric, detail text);

DROP TABLE IF EXISTS big CASCADE;
CREATE TABLE big (id int PRIMARY KEY, name text, hits int, note text);
INSERT INTO big SELECT g, 'row-' || g, g % 1000, NULL FROM generate_series(1, 1000000) g;
ANALYZE big;

DO $$
DECLARE t0 timestamptz := clock_timestamp();
BEGIN
  UPDATE big SET hits = hits + 1 WHERE id <= 10000;
  INSERT INTO bench_results VALUES ('write_10k_untracked',
    extract(epoch FROM clock_timestamp() - t0) * 1000, '10k updates, no journal trigger')
  ON CONFLICT (step) DO UPDATE SET ms = EXCLUDED.ms;
END $$;

SELECT grove.track('big');

DO $$
DECLARE t0 timestamptz := clock_timestamp();
BEGIN
  UPDATE big SET hits = hits + 1 WHERE id <= 10000;
  INSERT INTO bench_results VALUES ('write_10k_tracked',
    extract(epoch FROM clock_timestamp() - t0) * 1000, '10k updates, journal trigger on')
  ON CONFLICT (step) DO UPDATE SET ms = EXCLUDED.ms;
END $$;
