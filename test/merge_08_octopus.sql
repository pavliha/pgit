BEGIN;
SELECT plan(19);

CREATE TABLE t (id int PRIMARY KEY, v text, hits int);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'base', 0 FROM generate_series(1,6) g;
CREATE TEMP TABLE base AS SELECT grove.commit('base','p') AS sha;

SELECT grove.branch('a');
SELECT grove.branch('b');
SELECT grove.branch('c');

SELECT grove.checkout('a');
UPDATE t SET v = 'from a' WHERE id = 1;
SELECT grove.commit('a edit','p');

SELECT grove.checkout('b');
UPDATE t SET v = 'from b' WHERE id = 2;
SELECT grove.commit('b edit','p');

SELECT grove.checkout('c');
UPDATE t SET v = 'from c' WHERE id = 3;
SELECT grove.commit('c edit','p');

SELECT grove.checkout('main');
UPDATE t SET v = 'from main' WHERE id = 4;
CREATE TEMP TABLE ours AS SELECT grove.commit('main edit','p') AS sha;

SELECT throws_like(
  $$ SELECT grove.merge_octopus(ARRAY['a']) $$,
  '%needs at least two branches%',
  'octopus: one branch is refused, that is what merge is for');

SELECT is(grove.merge_octopus(ARRAY['a','b','c']), 0, 'octopus: three branches merge in one call');

CREATE TEMP TABLE oct AS SELECT grove.resolve('main') AS sha;

SELECT is((SELECT count(*) FROM grove.parents_of((SELECT sha FROM oct))), 4::bigint,
  'octopus: the merge commit records four parents, ours and the three heads');

SELECT is(
  (SELECT p.parent FROM grove.parents_of((SELECT sha FROM oct)) p WHERE p.ord = 1),
  (SELECT sha FROM ours),
  'octopus: the first parent is the branch we merged into');

SELECT is(
  (SELECT array_agg(p.parent ORDER BY p.ord)
   FROM grove.parents_of((SELECT sha FROM oct)) p WHERE p.ord > 1),
  ARRAY[grove.resolve('a'), grove.resolve('b'), grove.resolve('c')],
  'octopus: the remaining parents are the heads in the order given');

SELECT is((SELECT string_agg(v, ',' ORDER BY id) FROM t),
  'from a,from b,from c,from main,base,base',
  'octopus: every branch''s change landed in one commit');

SELECT is(grove.rev('main^3'), grove.resolve('b'), 'octopus: HEAD^3 reaches the third parent');
SELECT is(grove.rev('main^4'), grove.resolve('c'), 'octopus: HEAD^4 reaches the fourth parent');
SELECT throws_like($$ SELECT grove.rev('main^5') $$, '%no such parent%',
  'octopus: asking for a parent past the last one fails');

SELECT is(grove.rev('main~1'), (SELECT sha FROM ours),
  'octopus: ~ still follows the first parent only');

SELECT is((SELECT count(*) FROM grove.log(grove.resolve('main')) l WHERE l.sha = (SELECT sha FROM oct)),
  1::bigint, 'octopus: log lists the merge commit once');

SELECT is((SELECT count(*) FROM grove.fsck()), 0::bigint, 'octopus: fsck is clean afterwards');
SELECT is(grove.is_dirty(), false, 'octopus: the working tree matches the commit it wrote');

SELECT is(grove.merge_octopus(ARRAY['a','b','c']), 0,
  'octopus: merging the same heads again is a no-op, they are already contained');
SELECT is((SELECT sha FROM oct), grove.resolve('main'),
  'octopus: the no-op moved nothing');

SELECT grove.branch('d');
SELECT grove.branch('e');
SELECT grove.checkout('d');
UPDATE t SET hits = 11 WHERE id = 5;
SELECT grove.commit('d edit','p');
SELECT grove.checkout('e');
UPDATE t SET hits = 22 WHERE id = 5;
SELECT grove.commit('e edit','p');
SELECT grove.checkout('main');

SELECT throws_like(
  $$ SELECT grove.merge_octopus(ARRAY['d','e']) $$,
  '%octopus refuses%t(id=5)%',
  'octopus: two heads changing one row differently is refused, naming the row');

SELECT is(grove.resolve('main'), (SELECT sha FROM oct),
  'octopus: the refusal left the branch where it was');

SELECT grove.branch('f');
SELECT grove.branch('g');
SELECT grove.checkout('f');
UPDATE t SET hits = 77 WHERE id = 6;
SELECT grove.commit('f edit','p');
SELECT grove.checkout('g');
UPDATE t SET hits = 77 WHERE id = 6;
SELECT grove.commit('g edit','p');
SELECT grove.checkout('main');

SELECT is(grove.merge_octopus(ARRAY['f','g']), 0,
  'octopus: two heads making the identical change is not a conflict');
SELECT is((SELECT hits FROM t WHERE id = 6), 77,
  'octopus: the agreed change was applied once');

SELECT * FROM finish();
ROLLBACK;
