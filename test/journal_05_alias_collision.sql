BEGIN;
SELECT plan(15);

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

-- The journal was fixed for n and o long ago. The row hash SQL and the replay
-- SQL had the same defect with different aliases: to_jsonb(t) over "FROM tbl t"
-- resolves to a column named t, so every stored image became a scalar and
-- checkout died on "cannot call populate_composite on a scalar" - after having
-- written a wrong tree.
CREATE TABLE probe2 (id int PRIMARY KEY, t text, s text, pgit_t text, v text);
SELECT pgit.track('probe2');
INSERT INTO probe2 VALUES (1, 'a', 'b', 'c', 'd'), (2, 'e', 'f', 'g', 'h');
CREATE TEMP TABLE p2base AS SELECT pgit.commit('probe2 base', 'main') AS sha;

SELECT is(
  jsonb_typeof((SELECT pgit.entries_of(root_hash) -> 0 FROM pgit.trees
                WHERE tbl = 'probe2' AND commit_sha = (SELECT sha FROM p2base))),
  'object',
  'alias: a table with columns t and s stores row objects in the tree, not scalars');

SELECT is(
  (SELECT pgit.entries_of(root_hash) -> 0 ->> 't' FROM pgit.trees
   WHERE tbl = 'probe2' AND commit_sha = (SELECT sha FROM p2base)),
  'a',
  'alias: and the column named t holds its own value, not the whole row');

SELECT is(
  pgit.write_tree('probe2'),
  (SELECT root_hash FROM pgit.trees WHERE tbl = 'probe2' AND commit_sha = (SELECT sha FROM p2base)),
  'alias: probe2 rebuilds to the recorded root');

SELECT pgit.branch('aliasside', (SELECT sha FROM p2base));
SELECT pgit.checkout('aliasside');
UPDATE probe2 SET t = 'changed' WHERE id = 2;
DELETE FROM probe2 WHERE id = 1;
SELECT pgit.commit('probe2 side', 'aliasside');
SELECT pgit.checkout('main');

SELECT is(
  (SELECT t FROM probe2 WHERE id = 2), 'e',
  'alias: checking out across a table with a column named t restores its value');

SELECT is(
  (SELECT count(*) FROM probe2)::int, 2,
  'alias: and the row the other branch deleted comes back');

SELECT throws_ok(
  $$CREATE TABLE reserved (id int PRIMARY KEY, "pgit row" text); SELECT pgit.track('reserved')$$,
  NULL,
  'alias: a column named "pgit row" is refused at track time rather than corrupting silently');

SELECT * FROM finish();
ROLLBACK;
