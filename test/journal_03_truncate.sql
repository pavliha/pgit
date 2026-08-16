BEGIN;
SELECT plan(4);

CREATE TABLE t (id int PRIMARY KEY, name text);
SELECT grove.track('t');

INSERT INTO t SELECT g, 'row-' || g FROM generate_series(1, 500) g;

DELETE FROM grove.changes WHERE tbl = 't';

TRUNCATE t;

SELECT is(
  (SELECT count(*) FROM grove.changes WHERE tbl = 't' AND op = 'DELETE'),
  500::bigint, 'AC-COMMIT-07: TRUNCATE journals every row it destroys'
);

SELECT is(
  (SELECT count(*) FROM t),
  0::bigint, 'AC-COMMIT-07: the table is actually empty afterwards'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM grove.changes
    WHERE tbl = 't' AND op = 'DELETE' AND (before IS NULL OR after IS NOT NULL)
  ),
  'AC-COMMIT-07: every truncate row carries a before image and no after image'
);

SELECT ok(
  (SELECT count(DISTINCT before ->> 'name') FROM grove.changes WHERE tbl = 't') = 500,
  'AC-COMMIT-07: the journalled rows are the real ones, not repeats'
);

SELECT * FROM finish();
ROLLBACK;
