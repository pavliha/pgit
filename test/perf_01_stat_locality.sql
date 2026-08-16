BEGIN;
SELECT plan(5);

DO $$
DECLARE i int;
BEGIN
  FOR i IN 1..50 LOOP
    EXECUTE format('CREATE TABLE t%s (id int PRIMARY KEY, name text, hits int)', i);
    EXECUTE format('INSERT INTO t%s SELECT g, ''row-'' || g, 0 FROM generate_series(1, 60) g', i);
    EXECUTE format('SELECT grove.track(''t%s'')', i);
  END LOOP;
END $$;

CREATE TEMP TABLE a AS SELECT grove.commit('fifty tables', 'bench') AS sha;

UPDATE t7 SET hits = 1 WHERE id <= 3;
CREATE TEMP TABLE b AS SELECT grove.commit('touch one table', 'bench') AS sha;

SELECT is(
  (SELECT count(*) FROM grove.trees WHERE commit_sha = (SELECT sha FROM a)), 50::bigint,
  'AC-PERF-03: all fifty tables are tracked and recorded'
);

SELECT is(
  (SELECT count(*) FROM grove.trees ta
   JOIN grove.trees tb ON tb.tbl = ta.tbl AND tb.commit_sha = (SELECT sha FROM b)
   WHERE ta.commit_sha = (SELECT sha FROM a) AND ta.root_hash = tb.root_hash),
  49::bigint,
  'AC-PERF-03: forty nine untouched tables keep an identical root hash, so their trees are shared'
);

SELECT is(
  (SELECT count(*) FROM grove.diff_stat((SELECT sha FROM a), (SELECT sha FROM b))), 1::bigint,
  'AC-PERF-03: stat reports exactly the one changed table'
);

CREATE TEMP TABLE blocks_one AS
SELECT pg_stat_get_xact_blocks_fetched('grove.nodes'::regclass) AS b0;

SELECT count(*) FROM grove.diff_stat((SELECT sha FROM a), (SELECT sha FROM b));

CREATE TEMP TABLE blocks_after_one AS
SELECT pg_stat_get_xact_blocks_fetched('grove.nodes'::regclass) AS b1;

DO $$
DECLARE i int;
BEGIN
  FOR i IN 1..50 LOOP
    EXECUTE format('UPDATE t%s SET hits = 2 WHERE id <= 3', i);
  END LOOP;
END $$;

CREATE TEMP TABLE c AS SELECT grove.commit('touch all fifty', 'bench') AS sha;

CREATE TEMP TABLE blocks_two AS
SELECT pg_stat_get_xact_blocks_fetched('grove.nodes'::regclass) AS b0;

SELECT count(*) FROM grove.diff_stat((SELECT sha FROM b), (SELECT sha FROM c));

CREATE TEMP TABLE blocks_after_two AS
SELECT pg_stat_get_xact_blocks_fetched('grove.nodes'::regclass) AS b1;

SELECT is(
  (SELECT count(*) FROM grove.diff_stat((SELECT sha FROM b), (SELECT sha FROM c))), 50::bigint,
  'AC-PERF-03: touching every table reports every table'
);

SELECT cmp_ok(
  ((SELECT b1 FROM blocks_after_one) - (SELECT b0 FROM blocks_one)) * 10,
  '<',
  ((SELECT b1 FROM blocks_after_two) - (SELECT b0 FROM blocks_two)),
  'AC-PERF-03: a one table diff fetches less than a tenth of the node blocks a fifty table diff does'
);

SELECT * FROM finish();
ROLLBACK;
