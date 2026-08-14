BEGIN;
SELECT plan(5);

CREATE TABLE t (id int PRIMARY KEY, name text);
SELECT pgit.track('t');
INSERT INTO t VALUES (1, 'one'), (2, 'two');
SELECT pgit.commit('base', 'pavlo');
SELECT pgit.branch('feature');

ALTER TABLE t ADD COLUMN extra text;
SELECT pgit.commit('main adds a column', 'pavlo');

SELECT throws_like(
  $$ SELECT pgit.checkout('feature') $$,
  '%different shape%',
  'AC-DDL: checkout across a schema change names the shape difference'
);

SELECT throws_like(
  $$ SELECT pgit.checkout('feature') $$,
  '%extra%',
  'AC-DDL: the error lists the columns, so the difference is visible without digging'
);

SELECT throws_like(
  $$ SELECT pgit.checkout('feature') $$,
  '%not shape%',
  'AC-DDL: the error explains why, rather than blaming uncommitted changes'
);

ALTER TABLE t DROP COLUMN extra;
SELECT pgit.commit('main drops the column again', 'pavlo');

SELECT lives_ok(
  $$ SELECT pgit.checkout('feature') $$,
  'AC-DDL: once the shape matches again, checkout succeeds'
);

SELECT is(pgit.head(), 'feature', 'AC-DDL: the checkout completed and moved HEAD');

SELECT * FROM finish();
ROLLBACK;
