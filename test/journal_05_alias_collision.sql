BEGIN;
SELECT plan(9);

-- n and o are the aliases the statement trigger used for its transition tables.
-- A bare to_jsonb(n) over "FROM newrows n" resolves n to the column, not the row,
-- so the journal recorded a scalar and the whole row was lost.
CREATE TABLE probe (id int PRIMARY KEY, n int, o text, cols text);
SELECT pgit.track('probe');

INSERT INTO probe VALUES (1, 42, 'oh', 'c1'), (2, 43, 'no', 'c2');

SELECT is(
  (SELECT jsonb_typeof(after) FROM pgit.changes WHERE tbl = 'probe' AND pk::text LIKE '%1%' LIMIT 1),
  'object',
  'alias: an insert journals a row object, not a bare column value');

SELECT is(
  (SELECT after FROM pgit.changes c WHERE c.tbl = 'probe' AND c.after ->> 'id' = '1'),
  '{"id": 1, "n": 42, "o": "oh", "cols": "c1"}'::jsonb,
  'alias: and the object holds every column, including the ones named n and o');

SELECT pgit.commit('inserted', 'p');
SELECT is(pgit.is_dirty(), false, 'alias: the commit round trips a table with colliding column names');

UPDATE probe SET n = 99, o = 'changed' WHERE id = 1;

SELECT is(
  (SELECT before FROM pgit.changes c
   WHERE c.tbl = 'probe' AND c.op = 'UPDATE' AND c.before ->> 'id' = '1'),
  '{"id": 1, "n": 42, "o": "oh", "cols": "c1"}'::jsonb,
  'alias: an update journals the whole previous row');

SELECT is(
  (SELECT after FROM pgit.changes c
   WHERE c.tbl = 'probe' AND c.op = 'UPDATE' AND c.after ->> 'id' = '1'),
  '{"id": 1, "n": 99, "o": "changed", "cols": "c1"}'::jsonb,
  'alias: and the whole new row');

SELECT pgit.commit('updated', 'p');
SELECT is(pgit.is_dirty(), false, 'alias: the update commit is clean too');

DELETE FROM probe WHERE id = 2;

SELECT is(
  (SELECT before FROM pgit.changes c
   WHERE c.tbl = 'probe' AND c.op = 'DELETE' AND c.before ->> 'id' = '2'),
  '{"id": 2, "n": 43, "o": "no", "cols": "c2"}'::jsonb,
  'alias: a delete journals the whole removed row');

SELECT pgit.commit('deleted', 'p');

SELECT is(
  (SELECT count(*) FROM pgit.diff(pgit.rev('main~2'), pgit.resolve('main'))), 2::bigint,
  'alias: the diff over both commits sees the update and the delete');

SELECT is(
  pgit.write_tree('probe'),
  (SELECT root_hash FROM pgit.trees WHERE commit_sha = pgit.resolve('main') AND tbl = 'probe'),
  'alias: and the tree matches a full rebuild throughout');

SELECT * FROM finish();
ROLLBACK;
