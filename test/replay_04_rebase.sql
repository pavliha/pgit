BEGIN;
SELECT plan(6);

CREATE TABLE t (id int PRIMARY KEY, name text, hits int);
SELECT pgit.track('t');
INSERT INTO t VALUES (1, 'one', 0), (2, 'two', 0), (3, 'three', 0);
SELECT pgit.commit('base', 'pavlo');

SELECT pgit.branch('feature');
SELECT pgit.checkout('feature');
UPDATE t SET hits = 99 WHERE id = 1;
CREATE TEMP TABLE f1 AS SELECT pgit.commit('feature work', 'pavlo') AS sha;

SELECT is(pgit.rebase('main'), 0, 'AC-REPLAY-08: rebase onto the current base is a no-op');

SELECT is(
  pgit.resolve('feature'), (SELECT sha FROM f1),
  'AC-REPLAY-08: the no-op rebase left the ref exactly where it was'
);

SELECT pgit.checkout('main');
UPDATE t SET name = 'main edit' WHERE id = 3;
CREATE TEMP TABLE m1 AS SELECT pgit.commit('main work', 'pavlo') AS sha;
SELECT pgit.checkout('feature');

SELECT is(pgit.rebase('main'), 0, 'AC-REPLAY-07: a non-conflicting rebase completes');

SELECT is(
  (SELECT hits FROM t WHERE id = 1)::text || '/' || (SELECT name FROM t WHERE id = 3),
  '99/main edit', 'AC-REPLAY-07: the rebased tree carries both branches changes'
);

SELECT isnt(
  pgit.resolve('feature'), (SELECT sha FROM f1),
  'AC-REPLAY-07: the replayed commit has a new sha'
);

SELECT is(
  (SELECT parent_sha FROM pgit.commits WHERE sha = pgit.resolve('feature')),
  (SELECT sha FROM m1),
  'AC-REPLAY-07: the rebased commit now sits directly on top of main'
);

SELECT * FROM finish();
ROLLBACK;
