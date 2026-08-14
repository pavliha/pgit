BEGIN;
SELECT plan(7);

CREATE TABLE t (id int PRIMARY KEY, name text, hits int);
SELECT pgit.track('t');
INSERT INTO t VALUES (1, 'original', 0), (2, 'original', 0), (3, 'original', 0);
CREATE TEMP TABLE base AS SELECT pgit.commit('base', 'pavlo') AS sha;

SELECT pgit.branch('feature');

UPDATE t SET name = 'main version' WHERE id = 1;
DELETE FROM t WHERE id = 2;
UPDATE t SET name = 'agreed' WHERE id = 3;
SELECT pgit.commit('main edits', 'pavlo');

SELECT pgit.checkout('feature');
UPDATE t SET name = 'feature version' WHERE id = 1;
UPDATE t SET name = 'still wanted' WHERE id = 2;
UPDATE t SET name = 'agreed' WHERE id = 3;
CREATE TEMP TABLE feature_head AS SELECT pgit.commit('feature edits', 'pavlo') AS sha;

SELECT is(pgit.merge('main'), 2, 'AC-MERGE-04: two conflicts are reported, not one and not three');

SELECT is(
  (SELECT count(*) FROM pgit.conflicts), 2::bigint,
  'AC-MERGE-11: conflicts are recorded in a queryable table'
);

SELECT is(
  (SELECT col FROM pgit.conflicts WHERE ours ->> 'id' = '1'), 'name',
  'AC-MERGE-04: a same column edit on both sides names the conflicting column'
);

SELECT is(
  (SELECT (base ->> 'name') || '|' || (ours ->> 'name') || '|' || (theirs ->> 'name')
   FROM pgit.conflicts WHERE ours ->> 'id' = '1'),
  'original|feature version|main version',
  'AC-MERGE-11: the conflict row carries all three sides'
);

SELECT is(
  (SELECT col FROM pgit.conflicts WHERE ours ->> 'id' = '2'), NULL,
  'AC-MERGE-06: a delete on one side and a modify on the other is a row level conflict'
);

SELECT ok(
  NOT EXISTS (SELECT 1 FROM pgit.conflicts WHERE ours ->> 'id' = '3'),
  'AC-MERGE-04: both branches making the identical change is not a conflict'
);

SELECT is(
  (SELECT name FROM t WHERE id = 1), 'feature version',
  'AC-MERGE-10: a conflicted merge applies nothing to the working tree'
);

SELECT * FROM finish();
ROLLBACK;
