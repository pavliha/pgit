BEGIN;
SELECT plan(9);

CREATE TABLE t (id int PRIMARY KEY, name text, hits int);
SELECT pgit.track('t');
INSERT INTO t VALUES (1, 'one', 5), (2, 'two', 7);
CREATE TEMP TABLE c1 AS SELECT pgit.commit('base', 'pavlo') AS sha;

SELECT is(
  (SELECT count(*) FROM pgit.schemas WHERE commit_sha = (SELECT sha FROM c1)), 1::bigint,
  'ddl: a commit records the shape of every tracked table'
);

SELECT pgit.branch('feature');
SELECT pgit.checkout('feature');
UPDATE t SET name = 'feature edit' WHERE id = 1;
CREATE TEMP TABLE f1 AS SELECT pgit.commit('feature edits data only', 'pavlo') AS sha;
SELECT pgit.checkout('main');

CREATE TEMP TABLE fp0 AS SELECT pgit.schema_fingerprint('t') AS fp, pgit.tree_root('t') AS root;

ALTER TABLE t ADD COLUMN extra text;

SELECT isnt(
  pgit.schema_fingerprint('t'), (SELECT fp FROM fp0),
  'AC-DDL-01: adding a column changes the schema fingerprint'
);

CREATE TEMP TABLE c2 AS SELECT pgit.commit('main adds a column', 'pavlo') AS sha;

SELECT ok(
  (SELECT columns::text FROM pgit.schemas WHERE commit_sha = (SELECT sha FROM c2)) LIKE '%extra%',
  'ddl: the new column is recorded in the commit shape'
);

SELECT throws_ok(
  format($$ SELECT pgit.cherry_pick(%L::bytea) $$, (SELECT sha FROM f1)),
  NULL, NULL,
  'AC-REPLAY-10: replaying a commit from before a schema change fails with a clear error'
);

SELECT throws_ok(
  $$ SELECT pgit.merge('feature') $$,
  NULL, NULL,
  'AC-MERGE-12: merging two branches whose shapes diverged is refused rather than attempted'
);

ALTER TABLE t DROP COLUMN extra;

SELECT is(
  pgit.schema_fingerprint('t'), (SELECT fp FROM fp0),
  'AC-DDL-02: dropping the added column restores the original fingerprint'
);

SELECT is(
  pgit.tree_root('t'), (SELECT root FROM fp0),
  'AC-DDL-02: a dropped column leaves no trace in the row canonical form'
);

ALTER TABLE t ALTER COLUMN hits TYPE bigint;

SELECT is(
  pgit.tree_root('t'), (SELECT root FROM fp0),
  'AC-DDL-04: widening integer to bigint preserves row identity exactly'
);

SELECT isnt(
  pgit.schema_fingerprint('t'), (SELECT fp FROM fp0),
  'AC-DDL-04: the type change is still visible in the schema fingerprint'
);

SELECT * FROM finish();
ROLLBACK;
