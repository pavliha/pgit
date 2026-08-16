BEGIN;
SELECT plan(14);

CREATE TABLE t1 (id int PRIMARY KEY, name text, hits int, note text);
SELECT grove.track('t1');
INSERT INTO t1 SELECT g, 'row-' || g, 0, NULL FROM generate_series(1, 100) g;

CREATE TEMP TABLE a AS SELECT grove.commit('a', 'pavlo') AS sha;

CREATE TABLE t2 (id int PRIMARY KEY, label text);
SELECT grove.track('t2');
INSERT INTO t2 VALUES (1, 'x'), (2, 'y');

UPDATE t1 SET name = 'changed' WHERE id = 5;
UPDATE t1 SET hits = 7 WHERE id = 6;
DELETE FROM t1 WHERE id = 7;
INSERT INTO t1 VALUES (500, 'new', 0, NULL);

CREATE TEMP TABLE b AS SELECT grove.commit('b', 'pavlo') AS sha;

SELECT is(
  (SELECT sum(inserted + updated + deleted)::bigint FROM grove.diff_stat((SELECT sha FROM a), (SELECT sha FROM b))),
  (SELECT count(*) FROM grove.diff((SELECT sha FROM a), (SELECT sha FROM b))),
  'AC-DIFF-06: stat counts sum to the full diff'
);

SELECT is(
  (SELECT inserted || '/' || updated || '/' || deleted
   FROM grove.diff_stat((SELECT sha FROM a), (SELECT sha FROM b)) WHERE tbl = 't1'),
  '1/2/1', 'AC-DIFF-06: stat splits t1 into one insert, two updates, one delete'
);

SELECT is(
  (SELECT added || '/' || removed FROM grove.diff_numstat((SELECT sha FROM a), (SELECT sha FROM b)) WHERE tbl = 't1'),
  '3/3', 'AC-DIFF-06: numstat counts an update as both an addition and a removal'
);

SELECT is(
  (SELECT tables FROM grove.diff_shortstat((SELECT sha FROM a), (SELECT sha FROM b))),
  2::bigint, 'AC-DIFF-06: shortstat counts both changed tables'
);

SELECT is(
  (SELECT string_agg(tbl, ',') FROM grove.diff_name_only((SELECT sha FROM a), (SELECT sha FROM b))),
  't1,t2', 'AC-DIFF-06: name-only lists each changed table once'
);

SELECT is(
  (SELECT status FROM grove.diff_name_status((SELECT sha FROM a), (SELECT sha FROM b)) WHERE tbl = 't1'),
  'M', 'AC-DIFF-06: an existing table is reported as modified'
);

SELECT is(
  (SELECT status FROM grove.diff_name_status((SELECT sha FROM a), (SELECT sha FROM b)) WHERE tbl = 't2'),
  'A', 'AC-DIFF-06: a table that appears only in the newer commit is reported as added'
);

SELECT is(
  (SELECT count(*) FROM grove.diff((SELECT sha FROM a), (SELECT sha FROM b), 't1')),
  (SELECT count(*) FROM grove.diff((SELECT sha FROM a), (SELECT sha FROM b)) WHERE tbl = 't1'),
  'AC-DIFF-07: a table pathspec equals the full diff filtered by table'
);

SELECT is(
  (SELECT count(*) FROM grove.diff((SELECT sha FROM a), (SELECT sha FROM b), 't1:5')),
  1::bigint, 'AC-DIFF-07: a row pathspec selects exactly one row'
);

SELECT is(
  (SELECT before ->> 'name' FROM grove.diff((SELECT sha FROM a), (SELECT sha FROM b), 't1:5')),
  'row-5', 'AC-DIFF-07: the row pathspec selects the right row'
);

SELECT is(
  (SELECT count(*) FROM grove.diff((SELECT sha FROM a), (SELECT sha FROM b), 't1.name')),
  3::bigint,
  'AC-DIFF-07: a column pathspec skips the row where only another column changed'
);

SELECT is(
  (SELECT before FROM grove.diff((SELECT sha FROM a), (SELECT sha FROM b), 't1.name') WHERE after ->> 'name' = 'changed'),
  '{"name": "row-5"}'::jsonb,
  'AC-DIFF-07: a column pathspec reduces the images to that column'
);

SELECT is(
  (SELECT count(*) FROM grove.diff((SELECT sha FROM a), (SELECT sha FROM b), 't1.note')),
  0::bigint,
  'AC-DIFF-07: a column that never changed reports nothing, even on inserted rows'
);

CREATE TABLE t3 (a int, b text, v int, PRIMARY KEY (a, b));
SELECT grove.track('t3');
INSERT INTO t3 VALUES (1, 'x', 9);
CREATE TEMP TABLE c AS SELECT grove.commit('c', 'pavlo') AS sha;

SELECT throws_ok(
  format($$ SELECT count(*) FROM grove.diff(%L::bytea, %L::bytea, 't3:1') $$,
         (SELECT sha FROM b), (SELECT sha FROM c)),
  NULL, NULL,
  'AC-DIFF-07: a row pathspec against a composite primary key fails loudly rather than silently returning nothing'
);

SELECT * FROM finish();
ROLLBACK;
