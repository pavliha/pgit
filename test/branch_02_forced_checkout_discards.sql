BEGIN;
SELECT plan(9);

CREATE TABLE t (id int PRIMARY KEY, v text);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'v'||g FROM generate_series(1,10) g;
SELECT grove.commit('base','alice');
SELECT grove.branch('other');
SELECT grove.checkout('other');
UPDATE t SET v = 'changed on other' WHERE id = 1;
SELECT grove.commit('other edits row 1','bob');
SELECT grove.checkout('main');

UPDATE t SET v = 'my uncommitted work' WHERE id = 2;

SELECT ok(grove.is_dirty(), 'forced checkout: there is uncommitted work to lose');
SELECT throws_like($$ SELECT grove.checkout('other') $$, '%uncommitted changes present%',
  'forced checkout: without force it refuses, which is what force overrides');

SELECT grove.checkout('other', true);

SELECT is((SELECT v FROM t WHERE id = 1), 'changed on other',
  'forced checkout: a row that differs between the branches takes the target value');
SELECT is((SELECT v FROM t WHERE id = 2), 'v2',
  'forced checkout: and a row that does not differ is still put back, work does not follow you across');
SELECT is(grove.write_tree('t'),
  (SELECT root_hash FROM grove.trees WHERE commit_sha = grove.resolve('other') AND tbl = 't'),
  'forced checkout: so the table matches the branch it now claims to be on');
SELECT ok(NOT grove.is_dirty(), 'forced checkout: and nothing is left pending');

UPDATE t SET v = 'more work' WHERE id = 3;
SELECT grove.checkout('other', true);

SELECT is((SELECT v FROM t WHERE id = 3), 'v3',
  'forced checkout: forcing onto the branch you are already on discards too, as git does');
SELECT ok(NOT grove.is_dirty(),
  'forced checkout: rather than reporting dirty forever with nothing able to clear it');

SELECT is((SELECT count(*) FROM grove.fsck()), 0::bigint,
  'forced checkout: and the store is sound throughout');

SELECT * FROM finish();
ROLLBACK;
