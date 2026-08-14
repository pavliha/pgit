BEGIN;
SELECT plan(8);

CREATE TABLE t (id int PRIMARY KEY, v text);
SELECT pgit.track('t');
INSERT INTO t SELECT g, 'v' || g FROM generate_series(1, 4000) g;
SELECT pgit.commit('wide', 'p');

SELECT cmp_ok(
  (SELECT count(*) FROM pgit.nodes_at_level(
     (SELECT root_hash FROM pgit.trees WHERE commit_sha = pgit.resolve('main') AND tbl = 't'), 0)),
  '>', 1::bigint,
  'collapse: the starting tree really has more than one leaf, so the shrink is a real shrink');

DELETE FROM t WHERE id > 20;
SELECT pgit.commit('shrunk to a single chunk', 'p');

CREATE TEMP TABLE after AS
SELECT root_hash AS h FROM pgit.trees WHERE commit_sha = pgit.resolve('main') AND tbl = 't';

SELECT is(
  (SELECT count(*) FROM pgit.nodes_at_level((SELECT h FROM after), 0)), 1::bigint,
  'collapse: the table now fits in a single chunk');

SELECT is(
  pgit.write_tree('t'), (SELECT h FROM after),
  'collapse: the incrementally spliced root equals a full rebuild of the same rows');

SELECT is(
  pgit.node_level((SELECT h FROM after)), 0,
  'collapse: and that root is the leaf itself, not a level 1 node wrapping it');

SELECT is(pgit.is_dirty(), false,
  'collapse: the working tree is clean straight after the shrinking commit');

SELECT is(
  (SELECT count(*) FROM pgit.diff(pgit.rev('main~1'), pgit.resolve('main'))), 3980::bigint,
  'collapse: the diff still reports every deleted row');

DELETE FROM t;
SELECT pgit.commit('emptied', 'p');

SELECT is(
  pgit.write_tree('t'),
  (SELECT root_hash FROM pgit.trees WHERE commit_sha = pgit.resolve('main') AND tbl = 't'),
  'collapse: emptying the table also agrees with a full rebuild');

INSERT INTO t SELECT g, 'again' || g FROM generate_series(1, 4000) g;
SELECT pgit.commit('regrown', 'p');

SELECT is(
  pgit.write_tree('t'),
  (SELECT root_hash FROM pgit.trees WHERE commit_sha = pgit.resolve('main') AND tbl = 't'),
  'collapse: growing back out of a single chunk agrees with a full rebuild too');

SELECT * FROM finish();
ROLLBACK;
