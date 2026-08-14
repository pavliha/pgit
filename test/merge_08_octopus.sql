BEGIN;
SELECT plan(19);

CREATE TABLE t (id int PRIMARY KEY, v text, hits int);
SELECT pgit.track('t');
INSERT INTO t SELECT g, 'base', 0 FROM generate_series(1,6) g;
CREATE TEMP TABLE base AS SELECT pgit.commit('base','p') AS sha;

SELECT pgit.branch('a');
SELECT pgit.branch('b');
SELECT pgit.branch('c');

SELECT pgit.checkout('a');
UPDATE t SET v = 'from a' WHERE id = 1;
SELECT pgit.commit('a edit','p');

SELECT pgit.checkout('b');
UPDATE t SET v = 'from b' WHERE id = 2;
SELECT pgit.commit('b edit','p');

SELECT pgit.checkout('c');
UPDATE t SET v = 'from c' WHERE id = 3;
SELECT pgit.commit('c edit','p');

SELECT pgit.checkout('main');
UPDATE t SET v = 'from main' WHERE id = 4;
CREATE TEMP TABLE ours AS SELECT pgit.commit('main edit','p') AS sha;

SELECT throws_like(
  $$ SELECT pgit.merge_octopus(ARRAY['a']) $$,
  '%needs at least two branches%',
  'octopus: one branch is refused, that is what merge is for');

SELECT is(pgit.merge_octopus(ARRAY['a','b','c']), 0, 'octopus: three branches merge in one call');

CREATE TEMP TABLE oct AS SELECT pgit.resolve('main') AS sha;

SELECT is((SELECT count(*) FROM pgit.parents_of((SELECT sha FROM oct))), 4::bigint,
  'octopus: the merge commit records four parents, ours and the three heads');

SELECT is(
  (SELECT p.parent FROM pgit.parents_of((SELECT sha FROM oct)) p WHERE p.ord = 1),
  (SELECT sha FROM ours),
  'octopus: the first parent is the branch we merged into');

SELECT is(
  (SELECT array_agg(p.parent ORDER BY p.ord)
   FROM pgit.parents_of((SELECT sha FROM oct)) p WHERE p.ord > 1),
  ARRAY[pgit.resolve('a'), pgit.resolve('b'), pgit.resolve('c')],
  'octopus: the remaining parents are the heads in the order given');

SELECT is((SELECT string_agg(v, ',' ORDER BY id) FROM t),
  'from a,from b,from c,from main,base,base',
  'octopus: every branch''s change landed in one commit');

SELECT is(pgit.rev('main^3'), pgit.resolve('b'), 'octopus: HEAD^3 reaches the third parent');
SELECT is(pgit.rev('main^4'), pgit.resolve('c'), 'octopus: HEAD^4 reaches the fourth parent');
SELECT throws_like($$ SELECT pgit.rev('main^5') $$, '%no such parent%',
  'octopus: asking for a parent past the last one fails');

SELECT is(pgit.rev('main~1'), (SELECT sha FROM ours),
  'octopus: ~ still follows the first parent only');

SELECT is((SELECT count(*) FROM pgit.log(pgit.resolve('main')) l WHERE l.sha = (SELECT sha FROM oct)),
  1::bigint, 'octopus: log lists the merge commit once');

SELECT is((SELECT count(*) FROM pgit.fsck()), 0::bigint, 'octopus: fsck is clean afterwards');
SELECT is(pgit.is_dirty(), false, 'octopus: the working tree matches the commit it wrote');

SELECT is(pgit.merge_octopus(ARRAY['a','b','c']), 0,
  'octopus: merging the same heads again is a no-op, they are already contained');
SELECT is((SELECT sha FROM oct), pgit.resolve('main'),
  'octopus: the no-op moved nothing');

SELECT pgit.branch('d');
SELECT pgit.branch('e');
SELECT pgit.checkout('d');
UPDATE t SET hits = 11 WHERE id = 5;
SELECT pgit.commit('d edit','p');
SELECT pgit.checkout('e');
UPDATE t SET hits = 22 WHERE id = 5;
SELECT pgit.commit('e edit','p');
SELECT pgit.checkout('main');

SELECT throws_like(
  $$ SELECT pgit.merge_octopus(ARRAY['d','e']) $$,
  '%octopus refuses%t(id=5)%',
  'octopus: two heads changing one row differently is refused, naming the row');

SELECT is(pgit.resolve('main'), (SELECT sha FROM oct),
  'octopus: the refusal left the branch where it was');

SELECT pgit.branch('f');
SELECT pgit.branch('g');
SELECT pgit.checkout('f');
UPDATE t SET hits = 77 WHERE id = 6;
SELECT pgit.commit('f edit','p');
SELECT pgit.checkout('g');
UPDATE t SET hits = 77 WHERE id = 6;
SELECT pgit.commit('g edit','p');
SELECT pgit.checkout('main');

SELECT is(pgit.merge_octopus(ARRAY['f','g']), 0,
  'octopus: two heads making the identical change is not a conflict');
SELECT is((SELECT hits FROM t WHERE id = 6), 77,
  'octopus: the agreed change was applied once');

SELECT * FROM finish();
ROLLBACK;
