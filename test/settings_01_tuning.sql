BEGIN;
SELECT plan(6);

CREATE TABLE tune (id int PRIMARY KEY, v text, n int);
SELECT grove.track('tune');
INSERT INTO tune SELECT g, 'v' || g, 0 FROM generate_series(1, 3000) g;
CREATE TEMP TABLE base_c AS SELECT grove.commit('tune base', 'main') AS sha;

SELECT is(
  (SELECT value FROM grove.meta WHERE key = 'max_tree_depth'), '40',
  'settings: max_tree_depth has a default');

UPDATE grove.meta SET value = '1' WHERE key = 'max_tree_depth';

SELECT throws_ok(
  $$SELECT grove.write_tree('tune')$$,
  NULL,
  'settings: lowering max_tree_depth really does stop the build, so it is read');

UPDATE grove.meta SET value = '40' WHERE key = 'max_tree_depth';

SELECT lives_ok(
  $$SELECT grove.write_tree('tune')$$,
  'settings: and restoring it lets the build finish again');

CREATE TEMP TABLE base_root AS
SELECT root_hash AS root FROM grove.trees
WHERE commit_sha = (SELECT sha FROM base_c) AND tbl = 'tune';

UPDATE tune SET n = 1 WHERE id % 7 = 0;

UPDATE grove.meta SET value = '100000' WHERE key = 'splice_max_changes_per_chunk';
CREATE TEMP TABLE spliced AS SELECT grove.write_tree_incremental('tune',
  (SELECT root_hash FROM grove.trees WHERE commit_sha = (SELECT sha FROM base_c) AND tbl = 'tune')) AS root;

UPDATE grove.meta SET value = '0' WHERE key = 'splice_max_changes_per_chunk';
CREATE TEMP TABLE ranged AS SELECT grove.write_tree_incremental('tune',
  (SELECT root_hash FROM grove.trees WHERE commit_sha = (SELECT sha FROM base_c) AND tbl = 'tune')) AS root;

UPDATE grove.meta SET value = '8' WHERE key = 'splice_max_changes_per_chunk';

SELECT isnt(
  (SELECT root FROM spliced), (SELECT root FROM base_root),
  'settings: the change really did move the root, so the comparison below is not vacuous');

SELECT is(
  (SELECT root FROM spliced), (SELECT root FROM ranged),
  'settings: splicing chunks and rebuilding their ranges produce the same tree');

SELECT is(
  (SELECT root FROM spliced), grove.write_tree('tune'),
  'settings: and both agree with a full rebuild');

SELECT * FROM finish();
ROLLBACK;
