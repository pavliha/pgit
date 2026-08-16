BEGIN;
SELECT plan(5);

CREATE TABLE t (id int PRIMARY KEY, name text);
SELECT grove.track('t');
INSERT INTO t VALUES (1, 'one'), (2, 'two');
SELECT grove.commit('base', 'pavlo');
SELECT grove.branch('feature');

ALTER TABLE t ADD COLUMN extra text;
SELECT grove.commit('main adds a column', 'pavlo');

SELECT throws_like(
  $$ SELECT grove.checkout('feature') $$,
  '%different shape%',
  'AC-DDL: checkout across a schema change names the shape difference'
);

SELECT throws_like(
  $$ SELECT grove.checkout('feature') $$,
  '%extra%',
  'AC-DDL: the error lists the columns, so the difference is visible without digging'
);

SELECT throws_like(
  $$ SELECT grove.checkout('feature') $$,
  '%not shape%',
  'AC-DDL: the error explains why, rather than blaming uncommitted changes'
);

ALTER TABLE t DROP COLUMN extra;
SELECT grove.commit('main drops the column again', 'pavlo');

SELECT lives_ok(
  $$ SELECT grove.checkout('feature') $$,
  'AC-DDL: once the shape matches again, checkout succeeds'
);

SELECT is(grove.head(), 'feature', 'AC-DDL: the checkout completed and moved HEAD');

SELECT * FROM finish();
ROLLBACK;
