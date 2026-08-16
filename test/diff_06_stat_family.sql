BEGIN;
SELECT plan(9);

CREATE TABLE p (id int PRIMARY KEY, name text NOT NULL, price int NOT NULL);
CREATE TABLE q (id int PRIMARY KEY, v text NOT NULL);
INSERT INTO p SELECT g, 'n' || g, g FROM generate_series(1, 100) g;
INSERT INTO q SELECT g, 'q' || g FROM generate_series(1, 50) g;
SELECT pgit.track('p');
SELECT pgit.track('q');
SELECT pgit.commit('base');

UPDATE p SET price = price + 1 WHERE id <= 10;
DELETE FROM p WHERE id = 99;
INSERT INTO p VALUES (200, 'new', 7);
UPDATE q SET v = 'changed' WHERE id <= 3;
SELECT pgit.commit('ten updates, one delete, one insert, and three elsewhere');

SELECT is(
  (SELECT (s.updated)::int FROM pgit.diff_stat(pgit.rev('HEAD~1'), pgit.rev('HEAD')) s WHERE s.tbl = 'p'), 10,
  'AC-DIFF-06: diff_stat counts the updated rows');

SELECT is(
  (SELECT (s.inserted)::int FROM pgit.diff_stat(pgit.rev('HEAD~1'), pgit.rev('HEAD')) s WHERE s.tbl = 'p'), 1,
  'AC-DIFF-06: and the inserted ones separately');

SELECT is(
  (SELECT (s.deleted)::int FROM pgit.diff_stat(pgit.rev('HEAD~1'), pgit.rev('HEAD')) s WHERE s.tbl = 'p'), 1,
  'AC-DIFF-06: and the deleted ones separately');

SELECT is(
  (SELECT (n.added)::int FROM pgit.diff_numstat(pgit.rev('HEAD~1'), pgit.rev('HEAD')) n WHERE n.tbl = 'p'), 11,
  'AC-DIFF-06: numstat counts an update as both an addition and a removal, like git on a line');

SELECT is(
  (SELECT (n.removed)::int FROM pgit.diff_numstat(pgit.rev('HEAD~1'), pgit.rev('HEAD')) n WHERE n.tbl = 'p'), 11,
  'AC-DIFF-06: so ten updates plus one insert and one delete is eleven each way');

SELECT is(
  (SELECT (s.insertions)::int FROM pgit.diff_shortstat(pgit.rev('HEAD~1'), pgit.rev('HEAD')) s), 14,
  'AC-DIFF-06: shortstat totals every table, eleven plus three');

SELECT is(
  (SELECT (s.tables)::int FROM pgit.diff_shortstat(pgit.rev('HEAD~1'), pgit.rev('HEAD')) s), 2,
  'AC-DIFF-06: and reports how many tables changed');

SELECT is(
  (SELECT count(*)::int FROM pgit.diff_name_status(pgit.rev('HEAD~1'), pgit.rev('HEAD')) s
   WHERE s.status = 'M'), 2,
  'AC-DIFF-06: name_status marks both tables modified');

SELECT is(
  (SELECT count(*)::int FROM pgit.diff_stat(pgit.rev('HEAD~1'), pgit.rev('HEAD'), 'q')), 1,
  'AC-DIFF-06: a pathspec narrows the report to one table');

SELECT * FROM finish();
ROLLBACK;
