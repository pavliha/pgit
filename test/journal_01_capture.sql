BEGIN;
SELECT plan(12);

CREATE TABLE t (id int PRIMARY KEY, name text, amount numeric);
SELECT grove.track('t');

SET LOCAL grove.actor = 'pavlo';
SET LOCAL grove.source = 'admin-ui';

INSERT INTO t VALUES (1, 'first', 10);

SELECT is(
  (SELECT op FROM grove.changes WHERE tbl = 't' ORDER BY id DESC LIMIT 1),
  'INSERT', 'journal: INSERT is captured'
);

SELECT is(
  (SELECT before FROM grove.changes WHERE tbl = 't' ORDER BY id DESC LIMIT 1),
  NULL, 'journal: INSERT records no before image'
);

SELECT is(
  (SELECT after ->> 'name' FROM grove.changes WHERE tbl = 't' ORDER BY id DESC LIMIT 1),
  'first', 'journal: INSERT records the after image'
);

SELECT is(
  (SELECT pk FROM grove.changes WHERE tbl = 't' ORDER BY id DESC LIMIT 1),
  '{"id": 1}'::jsonb, 'journal: the primary key is extracted'
);

SELECT is(
  (SELECT actor FROM grove.changes WHERE tbl = 't' ORDER BY id DESC LIMIT 1),
  'pavlo', 'journal: actor comes from SET LOCAL'
);

SELECT is(
  (SELECT source FROM grove.changes WHERE tbl = 't' ORDER BY id DESC LIMIT 1),
  'admin-ui', 'journal: source comes from SET LOCAL'
);

UPDATE t SET name = 'second' WHERE id = 1;

SELECT is(
  (SELECT before ->> 'name' || '->' || (after ->> 'name')
   FROM grove.changes WHERE tbl = 't' ORDER BY id DESC LIMIT 1),
  'first->second', 'journal: UPDATE records both images'
);

DELETE FROM t WHERE id = 1;

SELECT is(
  (SELECT op || ':' || (before ->> 'name') FROM grove.changes WHERE tbl = 't' ORDER BY id DESC LIMIT 1),
  'DELETE:second', 'journal: DELETE records the before image'
);

SELECT is(
  (SELECT count(*) FROM grove.changes WHERE tbl = 't'),
  3::bigint, 'journal: exactly three changes so far'
);

SELECT is(
  (SELECT count(DISTINCT txid) FROM grove.changes WHERE tbl = 't'),
  1::bigint, 'AC-COMMIT-01: all writes in one transaction share one txid'
);

CREATE TABLE no_pk (a int);

SELECT throws_ok(
  $$ SELECT grove.track('no_pk') $$,
  NULL,
  NULL,
  'AC-DDL-05: tracking a table with no primary key is refused'
);

CREATE TABLE composite (a int, b text, v int, PRIMARY KEY (a, b));
SELECT grove.track('composite');
INSERT INTO composite VALUES (1, 'x', 9);

SELECT is(
  (SELECT pk FROM grove.changes WHERE tbl = 'composite' ORDER BY id DESC LIMIT 1),
  '{"a": 1, "b": "x"}'::jsonb, 'AC-DDL-06: composite primary keys are extracted whole'
);

SELECT * FROM finish();
ROLLBACK;
