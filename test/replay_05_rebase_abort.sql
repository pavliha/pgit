BEGIN;
SELECT plan(4);

CREATE TABLE t (id int PRIMARY KEY, name text);
SELECT pgit.track('t');
INSERT INTO t VALUES (1, 'one'), (2, 'two');
SELECT pgit.commit('base', 'pavlo');

SELECT pgit.branch('feature');

UPDATE t SET name = 'main version' WHERE id = 2;
SELECT pgit.commit('main edits row 2', 'pavlo');

SELECT pgit.checkout('feature');
UPDATE t SET name = 'feature version' WHERE id = 2;
CREATE TEMP TABLE f1 AS SELECT pgit.commit('feature edits row 2', 'pavlo') AS sha;

SELECT is(
  pgit.rebase('main'), 1,
  'AC-REPLAY-09: rebase stops at the first conflicting commit and reports it'
);

SELECT is(
  (SELECT count(*) FROM pgit.rebase_state), 1::bigint,
  'AC-REPLAY-09: the interrupted rebase left resumable state behind'
);

SELECT pgit.rebase_abort();

SELECT is(
  pgit.resolve('feature'), (SELECT sha FROM f1),
  'AC-REPLAY-09: abort restores the pre-rebase ref exactly'
);

SELECT is(
  (SELECT name FROM t WHERE id = 2), 'feature version',
  'AC-REPLAY-09: abort restores the pre-rebase content'
);

SELECT * FROM finish();
ROLLBACK;
