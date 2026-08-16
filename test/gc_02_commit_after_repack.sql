BEGIN;
SELECT plan(4);

CREATE TABLE gp (id int PRIMARY KEY, v text NOT NULL);
INSERT INTO gp SELECT g, 'v' || g FROM generate_series(1, 40000) g;
SELECT grove.track('gp');
SELECT grove.commit('base');

SELECT cmp_ok(
  (SELECT n.level FROM grove.nodes n
   JOIN grove.trees t ON t.root_hash = n.hash
   WHERE t.commit_sha = grove.resolve('main') AND t.tbl = 'gp'),
  '>=', 2,
  'AC-GC-02: the tree is deep enough that commits take the incremental path');

SELECT grove.branch('release');
SELECT grove.checkout('release');
UPDATE gp SET v = 'release edit' WHERE id BETWEEN 100 AND 140;
SELECT grove.commit('work on release');
SELECT grove.checkout('main');

DO $$
DECLARE i int;
BEGIN
  FOR i IN 1..3 LOOP
    UPDATE gp SET v = 'main rev' || i WHERE id BETWEEN 100 AND 140;
    PERFORM grove.commit('main ' || i, NULL, now(), true);
  END LOOP;
END $$;

SELECT cmp_ok(grove.repack(), '>', 0, 'AC-GC-02: gc packs older node versions as deltas');

SELECT cmp_ok(
  (WITH live AS (
     SELECT g.h FROM grove.reachable_nodes(
       ARRAY[(SELECT root_hash FROM grove.trees
              WHERE commit_sha = grove.resolve('release') AND tbl = 'gp')]) g(h))
   SELECT count(*)::int FROM live JOIN grove.nodes n ON n.hash = live.h WHERE n.entries IS NULL),
  '>', 0,
  'AC-GC-02: and a branch that is not the newest writer ends up holding packed nodes');

SELECT grove.checkout('release');
UPDATE gp SET v = 'more release work' WHERE id = 120;
SELECT grove.commit('release again after gc');

SELECT is(
  grove.write_tree('gp'),
  (SELECT root_hash FROM grove.trees WHERE commit_sha = grove.resolve('release') AND tbl = 'gp'),
  'AC-GC-02: committing on that branch still records the tree the table holds, rather than dying on a packed chunk');

SELECT * FROM finish();
ROLLBACK;
