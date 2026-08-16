BEGIN;
SELECT plan(8);

CREATE TABLE alpha (id int PRIMARY KEY, v text NOT NULL);
CREATE TABLE beta  (id int PRIMARY KEY, v text NOT NULL);
INSERT INTO alpha SELECT g, 'alpha row ' || g FROM generate_series(1, 300) g;
INSERT INTO beta  SELECT g, 'beta row '  || g FROM generate_series(1, 300) g;
SELECT pgit.track('alpha');
SELECT pgit.track('beta');
SELECT pgit.commit('two tables');

ALTER TABLE alpha RENAME TO a2;
ALTER TABLE beta  RENAME TO b2;
SELECT pgit.commit('both renamed');

SELECT is(
  (SELECT count(*)::int FROM pgit.table_renames(pgit.rev('HEAD~1'), pgit.rev('HEAD'))), 2,
  'AC-RENAME-01: two tables renamed in one commit are both detected');

SELECT is(
  (SELECT r.new_tbl FROM pgit.table_renames(pgit.rev('HEAD~1'), pgit.rev('HEAD')) r
   WHERE r.old_tbl = 'alpha'), 'a2',
  'AC-RENAME-01: and each is paired with its own successor rather than cross matched');

SELECT is(
  (SELECT r.kind FROM pgit.table_renames(pgit.rev('HEAD~1'), pgit.rev('HEAD')) r
   WHERE r.old_tbl = 'beta'), 'identical',
  'AC-RENAME-01: an unchanged rename is reported as identical');

SELECT pgit.untrack('b2');
DROP TABLE b2;
CREATE TABLE unrelated (id int PRIMARY KEY, note text NOT NULL);
INSERT INTO unrelated SELECT g, 'completely different ' || g FROM generate_series(1, 300) g;
SELECT pgit.track('unrelated');
SELECT pgit.commit('dropped one, added another');

SELECT is(
  (SELECT count(*)::int FROM pgit.table_renames(pgit.rev('HEAD~1'), pgit.rev('HEAD'))), 0,
  'AC-RENAME-01: dropping one table and adding an unrelated one is not a rename');

CREATE TABLE src (id int PRIMARY KEY, v text NOT NULL);
INSERT INTO src SELECT g, 'row ' || g FROM generate_series(1, 400) g;
SELECT pgit.track('src');
SELECT pgit.commit('src added');

ALTER TABLE src RENAME TO dst;
UPDATE dst SET v = 'changed ' || id WHERE id % 4 = 0;
SELECT pgit.commit('renamed and a quarter changed');

SELECT is(
  (SELECT r.kind FROM pgit.table_renames(pgit.rev('HEAD~1'), pgit.rev('HEAD')) r
   WHERE r.old_tbl = 'src'), 'similar',
  'AC-RENAME-01: a rename that also changed rows is reported as similar, not identical');

SELECT is(
  (SELECT round(r.similarity, 2) FROM pgit.table_renames(pgit.rev('HEAD~1'), pgit.rev('HEAD')) r
   WHERE r.old_tbl = 'src'), 0.75,
  'AC-RENAME-01: with the similarity measured exactly, a quarter changed is 0.75');

SELECT is(
  (SELECT count(*)::int FROM pgit.table_renames(pgit.rev('HEAD~1'), pgit.rev('HEAD'), 0.95)), 0,
  'AC-RENAME-01: raising the threshold above that similarity reports nothing');

SELECT is(
  (SELECT count(*)::int FROM pgit.table_renames(pgit.rev('HEAD~1'), pgit.rev('HEAD'), 0.50)), 1,
  'AC-RENAME-01: lowering it below the similarity reports the pair again');

SELECT * FROM finish();
ROLLBACK;
