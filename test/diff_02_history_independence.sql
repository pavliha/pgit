BEGIN;
SELECT plan(4);

CREATE TABLE t (id int PRIMARY KEY, name text, hits int);
SELECT pgit.track('t');
INSERT INTO t SELECT g, 'row-' || g, 0 FROM generate_series(1, 500) g;

CREATE TEMP TABLE a AS SELECT pgit.commit('base', 'pavlo') AS sha;

DO $$
DECLARE i int;
BEGIN
  FOR i IN 1..20 LOOP
    UPDATE t SET hits = i WHERE id = 250;
    PERFORM pgit.commit('bump ' || i, 'pavlo');
  END LOOP;
END $$;

CREATE TEMP TABLE b AS SELECT pgit.resolve('main') AS sha;

SELECT is(
  (SELECT count(*) FROM pgit.commits),
  21::bigint, 'diff: twenty one commits exist'
);

SELECT is(
  (SELECT count(*) FROM pgit.diff((SELECT sha FROM a), (SELECT sha FROM b))),
  1::bigint,
  'AC-DIFF/PERF-02: a row updated twenty times across twenty commits is one change'
);

SELECT is(
  (SELECT after ->> 'hits' FROM pgit.diff((SELECT sha FROM a), (SELECT sha FROM b))),
  '20', 'AC-DIFF: the diff reports the final value, not the intermediate ones'
);

CREATE TABLE snapshot_a (LIKE t INCLUDING ALL);
INSERT INTO snapshot_a SELECT id, name, 0 FROM t;
SELECT pgit.apply_diff('snapshot_a', (SELECT sha FROM a), (SELECT sha FROM b), 't');

SELECT is(
  pgit.tree_root('snapshot_a'),
  (SELECT root_hash FROM pgit.trees WHERE commit_sha = (SELECT sha FROM b) AND tbl = 't'),
  'AC-DIFF-02: the round trip holds across twenty commits of history'
);

SELECT * FROM finish();
ROLLBACK;
