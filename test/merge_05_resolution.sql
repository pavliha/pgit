BEGIN;
SELECT plan(12);

CREATE TABLE t (id int PRIMARY KEY, name text, hits int);
SELECT grove.track('t');
INSERT INTO t VALUES (1,'orig',0),(2,'orig',0),(3,'orig',0);
SELECT grove.commit('base','p');
SELECT grove.branch('feature');

UPDATE t SET name='main' WHERE id=1;
UPDATE t SET name='only main touched this' WHERE id=3;
SELECT grove.commit('main edits','p');

SELECT grove.checkout('feature');
UPDATE t SET name='feature' WHERE id=1;
UPDATE t SET hits=9 WHERE id=2;
SELECT grove.commit('feature edits','p');

CREATE TEMP TABLE m AS SELECT grove.merge('main') AS n;
SELECT is((SELECT n FROM m), 1, 'merge reports the one conflict');

CREATE TEMP TABLE mid AS SELECT id FROM grove.merges;
SELECT is((SELECT count(*) FROM mid), 1::bigint, 'the in progress merge is recorded and resumable');

SELECT throws_like(
  format($$ SELECT grove.merge_finish(%s) $$, (SELECT id FROM mid)),
  '%unresolved%', 'merge_finish refuses while a conflict is unresolved');

SELECT grove.resolve_conflict((SELECT id FROM mid), 't',
  (SELECT k FROM grove.conflicts LIMIT 1), 'theirs');

SELECT is(grove.merge_finish((SELECT id FROM mid)), 0, 'merge_finish completes once resolved');
SELECT is((SELECT name FROM t WHERE id=1), 'main', 'the chosen side won');
SELECT is((SELECT name FROM t WHERE id=3), 'only main touched this',
  'a non conflicting change from the other branch still came across');
SELECT is((SELECT hits FROM t WHERE id=2), 9, 'our own non conflicting change survived');
SELECT is((SELECT count(*) FROM grove.merges), 0::bigint, 'the merge state was cleared');
SELECT is((SELECT count(*) FROM grove.parents_of(grove.resolve('feature'))), 2::bigint,
  'the result is a real merge commit with two parents');

CREATE TABLE u (id int PRIMARY KEY, v text);
SELECT grove.track('u');
INSERT INTO u VALUES (1,'orig');
SELECT grove.commit('u base','p');
SELECT grove.branch('side');
UPDATE u SET v='main side' WHERE id=1;
SELECT grove.commit('u main','p');
SELECT grove.checkout('side');
UPDATE u SET v='side side' WHERE id=1;
SELECT grove.commit('u side','p');

SELECT is(grove.merge('feature', NULL, 'ours'), 0, 'merge -X ours completes without stopping');
SELECT is((SELECT v FROM u WHERE id=1), 'side side', 'merge -X ours kept our value on the conflict');

SELECT grove.branch('third');
SELECT grove.checkout('third');
UPDATE u SET v='third' WHERE id=1;
SELECT grove.commit('u third','p');
SELECT grove.merge('feature', NULL, 'ours-tree');

SELECT is((SELECT v FROM u WHERE id=1), 'third',
  'merge -s ours keeps our tree entirely and still records the merge');

SELECT * FROM finish();
ROLLBACK;
