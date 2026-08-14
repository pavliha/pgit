BEGIN;
SELECT plan(12);

CREATE TABLE t (id int PRIMARY KEY, name text, hits int);
SELECT pgit.track('t');
INSERT INTO t VALUES (1,'orig',0),(2,'orig',0),(3,'orig',0);
SELECT pgit.commit('base','p');
SELECT pgit.branch('feature');

UPDATE t SET name='main' WHERE id=1;
UPDATE t SET name='only main touched this' WHERE id=3;
SELECT pgit.commit('main edits','p');

SELECT pgit.checkout('feature');
UPDATE t SET name='feature' WHERE id=1;
UPDATE t SET hits=9 WHERE id=2;
SELECT pgit.commit('feature edits','p');

CREATE TEMP TABLE m AS SELECT pgit.merge('main') AS n;
SELECT is((SELECT n FROM m), 1, 'merge reports the one conflict');

CREATE TEMP TABLE mid AS SELECT id FROM pgit.merges;
SELECT is((SELECT count(*) FROM mid), 1::bigint, 'the in progress merge is recorded and resumable');

SELECT throws_like(
  format($$ SELECT pgit.merge_finish(%s) $$, (SELECT id FROM mid)),
  '%unresolved%', 'merge_finish refuses while a conflict is unresolved');

SELECT pgit.resolve_conflict((SELECT id FROM mid), 't',
  (SELECT k FROM pgit.conflicts LIMIT 1), 'theirs');

SELECT is(pgit.merge_finish((SELECT id FROM mid)), 0, 'merge_finish completes once resolved');
SELECT is((SELECT name FROM t WHERE id=1), 'main', 'the chosen side won');
SELECT is((SELECT name FROM t WHERE id=3), 'only main touched this',
  'a non conflicting change from the other branch still came across');
SELECT is((SELECT hits FROM t WHERE id=2), 9, 'our own non conflicting change survived');
SELECT is((SELECT count(*) FROM pgit.merges), 0::bigint, 'the merge state was cleared');
SELECT isnt((SELECT parent2_sha FROM pgit.commits WHERE sha=pgit.resolve('feature')), NULL,
  'the result is a real merge commit with two parents');

CREATE TABLE u (id int PRIMARY KEY, v text);
SELECT pgit.track('u');
INSERT INTO u VALUES (1,'orig');
SELECT pgit.commit('u base','p');
SELECT pgit.branch('side');
UPDATE u SET v='main side' WHERE id=1;
SELECT pgit.commit('u main','p');
SELECT pgit.checkout('side');
UPDATE u SET v='side side' WHERE id=1;
SELECT pgit.commit('u side','p');

SELECT is(pgit.merge('feature', NULL, 'ours'), 0, 'merge -X ours completes without stopping');
SELECT is((SELECT v FROM u WHERE id=1), 'side side', 'merge -X ours kept our value on the conflict');

SELECT pgit.branch('third');
SELECT pgit.checkout('third');
UPDATE u SET v='third' WHERE id=1;
SELECT pgit.commit('u third','p');
SELECT pgit.merge('feature', NULL, 'ours-tree');

SELECT is((SELECT v FROM u WHERE id=1), 'third',
  'merge -s ours keeps our tree entirely and still records the merge');

SELECT * FROM finish();
ROLLBACK;
