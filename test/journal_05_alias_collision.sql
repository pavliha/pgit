BEGIN;
SELECT plan(15);

CREATE TABLE probe (id int PRIMARY KEY, n int, o text, cols text);
SELECT grove.track('probe');

INSERT INTO probe VALUES (1, 42, 'oh', 'c1'), (2, 43, 'no', 'c2');

SELECT is(
  (SELECT jsonb_typeof(after) FROM grove.changes WHERE tbl = 'probe' AND pk::text LIKE '%1%' LIMIT 1),
  'object',
  'alias: an insert journals a row object, not a bare column value');

SELECT is(
  (SELECT after FROM grove.changes c WHERE c.tbl = 'probe' AND c.after ->> 'id' = '1'),
  '{"id": 1, "n": 42, "o": "oh", "cols": "c1"}'::jsonb,
  'alias: and the object holds every column, including the ones named n and o');

SELECT grove.commit('inserted', 'p');
SELECT is(grove.is_dirty(), false, 'alias: the commit round trips a table with colliding column names');

UPDATE probe SET n = 99, o = 'changed' WHERE id = 1;

SELECT is(
  (SELECT before FROM grove.changes c
   WHERE c.tbl = 'probe' AND c.op = 'UPDATE' AND c.before ->> 'id' = '1'),
  '{"id": 1, "n": 42, "o": "oh", "cols": "c1"}'::jsonb,
  'alias: an update journals the whole previous row');

SELECT is(
  (SELECT after FROM grove.changes c
   WHERE c.tbl = 'probe' AND c.op = 'UPDATE' AND c.after ->> 'id' = '1'),
  '{"id": 1, "n": 99, "o": "changed", "cols": "c1"}'::jsonb,
  'alias: and the whole new row');

SELECT grove.commit('updated', 'p');
SELECT is(grove.is_dirty(), false, 'alias: the update commit is clean too');

DELETE FROM probe WHERE id = 2;

SELECT is(
  (SELECT before FROM grove.changes c
   WHERE c.tbl = 'probe' AND c.op = 'DELETE' AND c.before ->> 'id' = '2'),
  '{"id": 2, "n": 43, "o": "no", "cols": "c2"}'::jsonb,
  'alias: a delete journals the whole removed row');

SELECT grove.commit('deleted', 'p');

SELECT is(
  (SELECT count(*) FROM grove.diff(grove.rev('main~2'), grove.resolve('main'))), 2::bigint,
  'alias: the diff over both commits sees the update and the delete');

SELECT is(
  grove.write_tree('probe'),
  (SELECT root_hash FROM grove.trees WHERE commit_sha = grove.resolve('main') AND tbl = 'probe'),
  'alias: and the tree matches a full rebuild throughout');

CREATE TABLE probe2 (id int PRIMARY KEY, t text, s text, grove_t text, v text);
SELECT grove.track('probe2');
INSERT INTO probe2 VALUES (1, 'a', 'b', 'c', 'd'), (2, 'e', 'f', 'g', 'h');
CREATE TEMP TABLE p2base AS SELECT grove.commit('probe2 base', 'main') AS sha;

SELECT is(
  jsonb_typeof((SELECT grove.entries_of(root_hash) -> 0 FROM grove.trees
                WHERE tbl = 'probe2' AND commit_sha = (SELECT sha FROM p2base))),
  'object',
  'alias: a table with columns t and s stores row objects in the tree, not scalars');

SELECT is(
  (SELECT grove.entries_of(root_hash) -> 0 ->> 't' FROM grove.trees
   WHERE tbl = 'probe2' AND commit_sha = (SELECT sha FROM p2base)),
  'a',
  'alias: and the column named t holds its own value, not the whole row');

SELECT is(
  grove.write_tree('probe2'),
  (SELECT root_hash FROM grove.trees WHERE tbl = 'probe2' AND commit_sha = (SELECT sha FROM p2base)),
  'alias: probe2 rebuilds to the recorded root');

SELECT grove.branch('aliasside', (SELECT sha FROM p2base));
SELECT grove.checkout('aliasside');
UPDATE probe2 SET t = 'changed' WHERE id = 2;
DELETE FROM probe2 WHERE id = 1;
SELECT grove.commit('probe2 side', 'aliasside');
SELECT grove.checkout('main');

SELECT is(
  (SELECT t FROM probe2 WHERE id = 2), 'e',
  'alias: checking out across a table with a column named t restores its value');

SELECT is(
  (SELECT count(*) FROM probe2)::int, 2,
  'alias: and the row the other branch deleted comes back');

SELECT throws_ok(
  $$CREATE TABLE reserved (id int PRIMARY KEY, "grove row" text); SELECT grove.track('reserved')$$,
  NULL,
  'alias: a column named "grove row" is refused at track time rather than corrupting silently');

SELECT * FROM finish();
ROLLBACK;
