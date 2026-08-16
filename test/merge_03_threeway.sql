BEGIN;
SELECT plan(7);

CREATE TABLE t (id int PRIMARY KEY, name text, hits int);
SELECT grove.track('t');
INSERT INTO t VALUES (1, 'original', 0);
CREATE TEMP TABLE base AS SELECT grove.commit('base', 'pavlo') AS sha;

SELECT grove.branch('feature');

UPDATE t SET name = 'renamed on main' WHERE id = 1;
CREATE TEMP TABLE main_head AS SELECT grove.commit('main renames', 'pavlo') AS sha;

SELECT grove.checkout('feature');
UPDATE t SET hits = 99 WHERE id = 1;
SELECT grove.commit('feature counts', 'pavlo');

SELECT is(grove.merge('main'), 0, 'AC-MERGE-05: two branches editing different columns merge cleanly');

SELECT is(
  (SELECT name || '/' || hits FROM t WHERE id = 1), 'renamed on main/99',
  'AC-MERGE-05: the merged row carries both branches changes'
);

SELECT is(
  (SELECT p.parent FROM grove.parents_of(grove.resolve('feature')) p WHERE p.ord = 2),
  (SELECT sha FROM main_head),
  'merge: the merge commit records the second parent'
);

SELECT is(grove.merge('main'), 0, 'AC-MERGE-02: merging an already merged branch is a no-op');

SELECT is(
  (SELECT count(DISTINCT commit_sha) FROM grove.commit_parent), 1::bigint,
  'AC-MERGE-02: the second merge created no commit'
);

SELECT grove.branch('trailing', (SELECT sha FROM base));
SELECT grove.checkout('trailing');

SELECT is(grove.merge('feature'), 0, 'AC-MERGE-02: merging a descendant fast-forwards');

SELECT is(
  grove.resolve('trailing'), grove.resolve('feature'),
  'AC-MERGE-02: the fast-forward moved the ref to the descendant'
);

SELECT * FROM finish();
ROLLBACK;
