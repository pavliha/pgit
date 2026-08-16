BEGIN;
SELECT plan(3);

CREATE TABLE t (id int PRIMARY KEY, hits int);
SELECT grove.track('t');
INSERT INTO t SELECT g, 0 FROM generate_series(1, 5000) g;
CREATE TEMP TABLE base AS SELECT grove.commit('base', 'bench') AS sha;

DO $$
DECLARE i int;
BEGIN
  FOR i IN 1..300 LOOP
    UPDATE t SET hits = i WHERE id = 2500;
    PERFORM grove.commit('bump ' || i, 'bench');
  END LOOP;
END $$;

SELECT is(
  (SELECT count(*) FROM grove.commits), 301::bigint,
  'incremental: 300 commits inside one transaction complete without exhausting locks'
);

SELECT is(
  (SELECT count(*) FROM grove.diff((SELECT sha FROM base), grove.resolve('main'))), 1::bigint,
  'incremental: one row differs across all 300 commits'
);

SELECT is(
  grove.write_tree_incremental('t', (SELECT root_hash FROM grove.trees
                                    WHERE commit_sha = grove.resolve('main') AND tbl = 't')),
  grove.write_tree('t'),
  'incremental: after 300 in-transaction commits the tree still matches a full rebuild'
);

SELECT * FROM finish();
ROLLBACK;
