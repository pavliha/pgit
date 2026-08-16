BEGIN;
SELECT plan(4);

CREATE TABLE t1 (id int PRIMARY KEY, a text, b int);
INSERT INTO t1 VALUES (1, 'x', 10), (2, 'y', 20), (3, 'z', 30);

CREATE TEMP TABLE snap AS SELECT grove.tree_root('t1') AS root;

ALTER TABLE t1 ADD COLUMN zz text;

SELECT isnt(
  grove.tree_root('t1'),
  (SELECT root FROM snap),
  'AC-CANON-01: adding a column changes the canonical form'
);

ALTER TABLE t1 DROP COLUMN zz;

SELECT is(
  grove.tree_root('t1'),
  (SELECT root FROM snap),
  'AC-CANON-01: dropping the added column restores the original hash'
);

CREATE TABLE t2 (b int, a text, id int PRIMARY KEY);
INSERT INTO t2 (id, a, b) VALUES (1, 'x', 10), (2, 'y', 20), (3, 'z', 30);

SELECT is(
  grove.tree_root('t2'),
  (SELECT root FROM snap),
  'AC-CANON-01: physical column order does not affect the hash'
);

CREATE TABLE t3 (id int PRIMARY KEY, a text, b int, drop_me text);
INSERT INTO t3 (id, a, b, drop_me) VALUES (1, 'x', 10, 'junk'), (2, 'y', 20, 'junk'), (3, 'z', 30, 'junk');
ALTER TABLE t3 DROP COLUMN drop_me;

SELECT is(
  grove.tree_root('t3'),
  (SELECT root FROM snap),
  'AC-CANON-01: a table that once had an extra column matches one that never did'
);

SELECT * FROM finish();
ROLLBACK;
