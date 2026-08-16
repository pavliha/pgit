BEGIN;
SELECT plan(6);

CREATE TABLE t (id int PRIMARY KEY, v text, n int);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'v'||g, g FROM generate_series(1,50) g;
SELECT grove.commit('base','alice');
SELECT grove.branch('side');
SELECT grove.checkout('side');
UPDATE t SET n = n + 100 WHERE id <= 5;
CREATE TEMP TABLE pick AS SELECT grove.commit('side bump','bob') AS sha;
SELECT grove.checkout('main');

SELECT is((SELECT n FROM t WHERE id = 1), 1,
  'applied twice: main has not seen the change yet');

SELECT grove.cherry_pick((SELECT sha FROM pick));
SELECT is((SELECT n FROM t WHERE id = 1), 101,
  'applied twice: cherry picking brings it over');

SELECT grove.cherry_pick((SELECT sha FROM pick));
SELECT is((SELECT n FROM t WHERE id = 1), 101,
  'applied twice: picking the same commit again does not add the change on top of itself');

SELECT is((SELECT count(*) FROM grove.fsck()), 0::bigint,
  'applied twice: and the store is still sound');

SELECT grove.repack(4);
SELECT is(grove.repack(4), 0,
  'applied twice: a second repack finds nothing left to pack rather than packing what it packed');

SELECT grove.tag('v1');
SELECT throws_like($$ SELECT grove.tag('v1') $$, '%already exists%',
  'applied twice: a tag that is already there is refused rather than moved silently');

SELECT * FROM finish();
ROLLBACK;
