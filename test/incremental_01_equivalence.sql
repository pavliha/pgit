BEGIN;
SELECT plan(4);

CREATE TABLE t (id int PRIMARY KEY, name text, hits int);
SELECT pgit.track('t');
INSERT INTO t SELECT g, 'row-' || g, 0 FROM generate_series(1, 2000) g;
SELECT pgit.commit('base', 'fuzz');

CREATE TEMP TABLE mismatch (round int, inc bytea, full_root bytea);

DO $$
DECLARE
  i int; j int; r int; k int;
  prev bytea; inc bytea; fullr bytea;
BEGIN
  PERFORM setseed(0.7);
  prev := (SELECT root_hash FROM pgit.trees
           WHERE commit_sha = pgit.resolve('main') AND tbl = 't');

  FOR i IN 1..30 LOOP
    FOR j IN 1..6 LOOP
      r := (random() * 2.999)::int;
      k := 1 + (random() * 1999)::int;
      IF r = 0 THEN
        INSERT INTO t VALUES (k, 'v' || (random() * 1000)::int, (random() * 50)::int)
        ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;
      ELSIF r = 1 THEN
        UPDATE t SET hits = (random() * 50)::int WHERE id = k;
      ELSE
        DELETE FROM t WHERE id = k;
      END IF;
    END LOOP;

    inc   := pgit.write_tree_incremental('t', prev);
    fullr := pgit.write_tree('t');

    IF inc IS DISTINCT FROM fullr THEN
      INSERT INTO mismatch VALUES (i, inc, fullr);
    END IF;

    PERFORM pgit.commit('round ' || i, 'fuzz');
    prev := fullr;
  END LOOP;
END $$;

SELECT is(
  (SELECT count(*) FROM mismatch), 0::bigint,
  'incremental: the incrementally maintained root equals the full rebuild after every one of 30 rounds'
);

SELECT is(
  (SELECT count(*) FROM pgit.commits), 31::bigint,
  'incremental: the fuzz ran the expected number of commits'
);

DELETE FROM t WHERE id IN (SELECT id FROM t ORDER BY id LIMIT 300);
CREATE TEMP TABLE prev2 AS
  SELECT root_hash AS root FROM pgit.trees
  WHERE commit_sha = pgit.resolve('main') AND tbl = 't';

SELECT is(
  pgit.write_tree_incremental('t', (SELECT root FROM prev2)),
  pgit.write_tree('t'),
  'incremental: a bulk delete of 300 consecutive rows still matches the full rebuild'
);

SELECT pgit.commit('bulk delete', 'fuzz');

INSERT INTO t SELECT g, 'late-' || g, 1 FROM generate_series(5000, 5400) g;
CREATE TEMP TABLE prev3 AS
  SELECT root_hash AS root FROM pgit.trees
  WHERE commit_sha = pgit.resolve('main') AND tbl = 't';

SELECT is(
  pgit.write_tree_incremental('t', (SELECT root FROM prev3)),
  pgit.write_tree('t'),
  'incremental: appending 400 rows past the end still matches the full rebuild'
);

SELECT * FROM finish();
ROLLBACK;
