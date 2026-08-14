BEGIN;
SELECT plan(7);

CREATE TABLE t (id int PRIMARY KEY, name text, hits int);
SELECT pgit.track('t');
INSERT INTO t VALUES (1, 'original', 0);
CREATE TEMP TABLE base AS SELECT pgit.commit('base', 'pavlo') AS sha;

SELECT pgit.branch('feature');

UPDATE t SET name = 'renamed on main' WHERE id = 1;
CREATE TEMP TABLE main_head AS SELECT pgit.commit('main renames', 'pavlo') AS sha;

SELECT pgit.checkout('feature');
UPDATE t SET hits = 99 WHERE id = 1;
SELECT pgit.commit('feature counts', 'pavlo');

SELECT is(pgit.merge('main'), 0, 'AC-MERGE-05: two branches editing different columns merge cleanly');

SELECT is(
  (SELECT name || '/' || hits FROM t WHERE id = 1), 'renamed on main/99',
  'AC-MERGE-05: the merged row carries both branches changes'
);

SELECT is(
  (SELECT p.parent FROM pgit.parents_of(pgit.resolve('feature')) p WHERE p.ord = 2),
  (SELECT sha FROM main_head),
  'merge: the merge commit records the second parent'
);

SELECT is(pgit.merge('main'), 0, 'AC-MERGE-02: merging an already merged branch is a no-op');

SELECT is(
  (SELECT count(DISTINCT commit_sha) FROM pgit.commit_parent), 1::bigint,
  'AC-MERGE-02: the second merge created no commit'
);

SELECT pgit.branch('trailing', (SELECT sha FROM base));
SELECT pgit.checkout('trailing');

SELECT is(pgit.merge('feature'), 0, 'AC-MERGE-02: merging a descendant fast-forwards');

SELECT is(
  pgit.resolve('trailing'), pgit.resolve('feature'),
  'AC-MERGE-02: the fast-forward moved the ref to the descendant'
);

SELECT * FROM finish();
ROLLBACK;
