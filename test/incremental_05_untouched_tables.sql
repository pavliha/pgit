BEGIN;
SELECT plan(10);

CREATE TABLE small (id int PRIMARY KEY, v text);
CREATE TABLE big   (id int PRIMARY KEY, v text, body text);
SELECT pgit.track('small');
SELECT pgit.track('big');

INSERT INTO small SELECT g, 'v' || g FROM generate_series(1, 50) g;
INSERT INTO big   SELECT g, 'v' || g, repeat('payload ', 10) || g FROM generate_series(1, 50000) g;
CREATE TEMP TABLE c0 AS SELECT pgit.commit('base', 'p') AS sha;

CREATE TEMP TABLE roots0 AS
SELECT tbl, root_hash FROM pgit.trees WHERE commit_sha = (SELECT sha FROM c0);

SELECT cmp_ok(
  (SELECT count(*) FROM pgit.nodes_at_level((SELECT root_hash FROM roots0 WHERE tbl = 'big'), 0)),
  '>', 100::bigint,
  'untouched: the big table really is many chunks, so rebuilding it would be expensive');

UPDATE small SET v = 'changed' WHERE id = 1;
CREATE TEMP TABLE c1 AS SELECT pgit.commit('touch only the small table', 'p') AS sha;

SELECT is(
  (SELECT root_hash FROM pgit.trees WHERE commit_sha = (SELECT sha FROM c1) AND tbl = 'big'),
  (SELECT root_hash FROM roots0 WHERE tbl = 'big'),
  'untouched: the untouched table keeps exactly the root the parent recorded');

SELECT isnt(
  (SELECT root_hash FROM pgit.trees WHERE commit_sha = (SELECT sha FROM c1) AND tbl = 'small'),
  (SELECT root_hash FROM roots0 WHERE tbl = 'small'),
  'untouched: while the table that did change got a new root');

SELECT is(
  pgit.write_tree('big'),
  (SELECT root_hash FROM pgit.trees WHERE commit_sha = (SELECT sha FROM c1) AND tbl = 'big'),
  'untouched: and that reused root is what a full rebuild produces anyway');

SELECT is(pgit.is_dirty(), false, 'untouched: the working tree is clean after the commit');

UPDATE big SET v = 'now changed' WHERE id = 12345;
CREATE TEMP TABLE c2 AS SELECT pgit.commit('touch the big table', 'p') AS sha;

SELECT isnt(
  (SELECT root_hash FROM pgit.trees WHERE commit_sha = (SELECT sha FROM c2) AND tbl = 'big'),
  (SELECT root_hash FROM roots0 WHERE tbl = 'big'),
  'untouched: changing the big table does move its root');

SELECT is(
  pgit.write_tree('big'),
  (SELECT root_hash FROM pgit.trees WHERE commit_sha = (SELECT sha FROM c2) AND tbl = 'big'),
  'untouched: and the spliced root still equals a full rebuild');

SELECT is(
  (SELECT count(*) FROM pgit.diff((SELECT sha FROM c1), (SELECT sha FROM c2))), 1::bigint,
  'untouched: the diff across that commit reports exactly the one changed row');

SELECT is(
  (SELECT count(*) FROM pgit.diff((SELECT sha FROM c0), (SELECT sha FROM c1), 'big')), 0::bigint,
  'untouched: and no phantom changes are attributed to the table nobody touched');

CREATE TEMP TABLE t_ms (what text PRIMARY KEY, ms numeric);
DO $$
DECLARE t0 timestamptz;
BEGIN
  UPDATE small SET v = 'timing probe' WHERE id = 2;
  t0 := clock_timestamp();
  PERFORM pgit.commit('timing: touch only the small table', 'p');
  INSERT INTO t_ms VALUES ('commit', extract(epoch FROM clock_timestamp() - t0) * 1000);

  t0 := clock_timestamp();
  PERFORM pgit.write_tree('big');
  INSERT INTO t_ms VALUES ('rebuild_big', extract(epoch FROM clock_timestamp() - t0) * 1000);
END $$;

SELECT cmp_ok(
  (SELECT ms FROM t_ms WHERE what = 'commit'), '<',
  (SELECT ms / 5 FROM t_ms WHERE what = 'rebuild_big'),
  'untouched: that commit costs under a fifth of one rebuild of the table it did not touch');

SELECT * FROM finish();
ROLLBACK;
