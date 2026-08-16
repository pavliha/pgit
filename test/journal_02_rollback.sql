BEGIN;
SELECT plan(5);

CREATE TABLE t (id int PRIMARY KEY, name text);
SELECT grove.track('t');

INSERT INTO t VALUES (1, 'kept');

SAVEPOINT sp;
INSERT INTO t VALUES (2, 'discarded');
INSERT INTO t VALUES (3, 'discarded');

SELECT is(
  (SELECT count(*) FROM grove.changes WHERE tbl = 't'),
  3::bigint, 'journal: three changes recorded before rollback'
);

ROLLBACK TO SAVEPOINT sp;

SELECT is(
  (SELECT count(*) FROM grove.changes WHERE tbl = 't'),
  1::bigint, 'AC-COMMIT-03: rolling back to a savepoint discards its journal rows'
);

SELECT is(
  (SELECT after ->> 'name' FROM grove.changes WHERE tbl = 't'),
  'kept', 'AC-COMMIT-03: the surviving change is the one before the savepoint'
);

SELECT is(
  (SELECT count(*) FROM t),
  1::bigint, 'journal: the table itself rolled back too'
);

CREATE TABLE untracked_after (id int PRIMARY KEY, v text);
SELECT grove.track('untracked_after');
INSERT INTO untracked_after VALUES (1, 'a');
SELECT grove.untrack('untracked_after');
INSERT INTO untracked_after VALUES (2, 'b');

SELECT is(
  (SELECT count(*) FROM grove.changes WHERE tbl = 'untracked_after'),
  1::bigint, 'journal: untrack stops recording'
);

SELECT * FROM finish();
ROLLBACK;
