DO $$
DECLARE t0 timestamptz; s bytea;
BEGIN
  ALTER TABLE big ADD COLUMN added_col text;
  t0 := clock_timestamp();
  s := grove.commit('add a column', 'bench');
  INSERT INTO bench_results VALUES ('commit_after_add_column',
    extract(epoch FROM clock_timestamp() - t0) * 1000,
    'AC-DDL-01: every row canonical form changes, forcing a full tree rebuild')
  ON CONFLICT (step) DO UPDATE SET ms = EXCLUDED.ms, detail = EXCLUDED.detail;
END $$;
