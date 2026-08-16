BEGIN;
SELECT plan(9);

CREATE TABLE t (id int PRIMARY KEY, name text);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'row-'||g FROM generate_series(1,600) g;
SELECT grove.commit('base','alice');
SELECT grove.branch('other');

SELECT ok(NOT grove.is_dirty(), 'dirty: a freshly committed repository is clean');

UPDATE t SET name = 'temp' WHERE id = 3;
UPDATE t SET name = 'row-3' WHERE id = 3;

SELECT cmp_ok((SELECT count(*) FROM grove.changes WHERE commit_sha IS NULL), '>', 0::bigint,
  'dirty: undoing a change by hand still leaves rows in the journal');
SELECT ok(NOT grove.is_dirty(),
  'dirty: but the table matches the commit, so there is nothing to check out over');
SELECT throws_like($$ SELECT grove.commit('nothing really changed','bob') $$, '%nothing to commit%',
  'dirty: and commit agrees there is nothing to record');

UPDATE grove.meta SET value = '8' WHERE key = 'chunk_target';

SELECT isnt(grove.write_tree('t'),
  (SELECT root_hash FROM grove.trees WHERE commit_sha = grove.resolve('main') AND tbl = 't'),
  'dirty: retuning chunk_target really does move a full rebuild, so the case below is not vacuous');

SELECT ok(NOT grove.is_dirty(),
  'dirty: retuning a chunking knob is not uncommitted work, no row changed');
SELECT ok(grove.checkout('other') >= 0,
  'dirty: so checkout still runs, instead of wedging against a commit that refuses too');

SELECT grove.checkout('main');
UPDATE t SET name = 'really changed' WHERE id = 9;

SELECT ok(grove.is_dirty(), 'dirty: a real change is still reported');
SELECT ok(grove.commit('a real change','bob') IS NOT NULL,
  'dirty: and it commits');

SELECT * FROM finish();
ROLLBACK;
