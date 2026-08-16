BEGIN;
SELECT plan(9);

CREATE TABLE t (id int PRIMARY KEY, v text);
SELECT grove.track('t');
INSERT INTO t SELECT g*10, 'v'||g FROM generate_series(1,3000) g;
SELECT grove.commit('base','alice');

CREATE OR REPLACE FUNCTION pg_temp.leaves_now() RETURNS TABLE (h bytea)
LANGUAGE sql AS $$
  SELECT r.h FROM grove.reachable_nodes(
    ARRAY[(SELECT root_hash FROM grove.trees
           WHERE commit_sha = grove.resolve('main') AND tbl = 't')]) r
  JOIN grove.nodes n ON n.hash = r.h
  WHERE n.level = 0
$$;

CREATE TEMP TABLE b0 AS SELECT h FROM pg_temp.leaves_now();

SELECT cmp_ok((SELECT count(*) FROM b0), '>', 20::bigint,
  'one edit one chunk: the table really is split into many chunks, so locality means something');

INSERT INTO t VALUES (15005, 'inserted between two existing keys');
SELECT grove.commit('insert','bob');
CREATE TEMP TABLE b1 AS SELECT h FROM pg_temp.leaves_now();

SELECT is((SELECT count(*) FROM b1 WHERE h NOT IN (SELECT h FROM b0)), 1::bigint,
  'one edit one chunk: inserting a row rewrites exactly one chunk');
SELECT is((SELECT count(*) FROM b1 WHERE h IN (SELECT h FROM b0)),
          (SELECT count(*) - 1 FROM b1),
  'one edit one chunk: and leaves every other chunk byte for byte as it was');

UPDATE t SET v = 'changed' WHERE id = 20000;
SELECT grove.commit('update','bob');
CREATE TEMP TABLE b2 AS SELECT h FROM pg_temp.leaves_now();

SELECT is((SELECT count(*) FROM b2 WHERE h NOT IN (SELECT h FROM b1)), 1::bigint,
  'one edit one chunk: changing a value rewrites exactly one chunk');
SELECT is((SELECT count(*) FROM b2), (SELECT count(*) FROM b1),
  'one edit one chunk: and does not change how many chunks there are, the key did not move');

DELETE FROM t WHERE id = 25000;
SELECT grove.commit('delete','bob');
CREATE TEMP TABLE b3 AS SELECT h FROM pg_temp.leaves_now();

SELECT cmp_ok((SELECT count(*) FROM b3 WHERE h NOT IN (SELECT h FROM b2)), '<=', 2::bigint,
  'one edit one chunk: deleting a row disturbs at most the chunk it was in and its neighbour');

SELECT is((SELECT count(*) FROM grove.fsck()), 0::bigint,
  'one edit one chunk: the store is sound after all three');

SELECT is(grove.write_tree('t'),
  (SELECT root_hash FROM grove.trees WHERE commit_sha = grove.resolve('main') AND tbl = 't'),
  'one edit one chunk: and the incremental builds agree with a rebuild from scratch');

UPDATE t SET v = 'bulk change' WHERE id % 1000 = 0;
SELECT grove.commit('many rows changed','bob');
CREATE TEMP TABLE b4 AS SELECT h FROM pg_temp.leaves_now();

SELECT cmp_ok((SELECT count(*) FROM b4 WHERE h NOT IN (SELECT h FROM b3)), '>', 10::bigint,
  'one edit one chunk: a change spread across the table does rewrite many chunks, so the counts above are measuring locality and not a constant');

SELECT * FROM finish();
ROLLBACK;
