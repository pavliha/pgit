BEGIN;
SELECT plan(6);

CREATE TABLE t (id int PRIMARY KEY, name text, hits int);
SELECT pgit.track('t');

INSERT INTO t SELECT g, 'row-' || g, 0 FROM generate_series(1, 100) g;

SELECT is(
  (SELECT count(*) FROM pgit.changes WHERE tbl = 't' AND op = 'INSERT'), 100::bigint,
  'journal: one multi row INSERT statement journals every row'
);

SELECT is(
  (SELECT count(DISTINCT txid) FROM pgit.changes WHERE tbl = 't'), 1::bigint,
  'journal: the statement level trigger still groups by transaction'
);

DELETE FROM pgit.changes WHERE tbl = 't';
UPDATE t SET hits = hits + 1 WHERE id <= 40;

SELECT is(
  (SELECT count(*) FROM pgit.changes WHERE tbl = 't' AND op = 'UPDATE'), 40::bigint,
  'journal: one multi row UPDATE journals each row with both images'
);

SELECT is(
  (SELECT before ->> 'hits' || '->' || (after ->> 'hits')
   FROM pgit.changes WHERE tbl = 't' AND pk = '{"id": 5}'::jsonb),
  '0->1', 'journal: the old and new images are matched to the right row'
);

DELETE FROM pgit.changes WHERE tbl = 't';
UPDATE t SET id = 5000 WHERE id = 99;

SELECT is(
  (SELECT string_agg(op, ',' ORDER BY op) FROM pgit.changes WHERE tbl = 't'),
  'DELETE,INSERT',
  'journal: changing a primary key is recorded as a delete and an insert, because the key is the identity'
);

DELETE FROM pgit.changes WHERE tbl = 't';
DELETE FROM t WHERE id <= 20;

SELECT is(
  (SELECT count(*) FROM pgit.changes WHERE tbl = 't' AND op = 'DELETE'), 20::bigint,
  'journal: one multi row DELETE journals every removed row'
);

SELECT * FROM finish();
ROLLBACK;
