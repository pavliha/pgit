BEGIN;
SELECT plan(8);

CREATE TABLE t (id int PRIMARY KEY, name text);
INSERT INTO t SELECT g, 'row-' || g FROM generate_series(1, 5000) g;

DELETE FROM pgit.nodes;

SELECT isnt(pgit.write_tree('t'), NULL, 'objects: write_tree returns a root');

SELECT ok(
  (SELECT count(*) FROM pgit.nodes) > 1,
  'objects: a 5000 row table produces more than one node'
);

SELECT ok(
  EXISTS (SELECT 1 FROM pgit.nodes WHERE hash = pgit.write_tree('t')),
  'objects: the root is itself a stored node'
);

SELECT is(
  (SELECT sum(jsonb_array_length(entries))::bigint FROM pgit.nodes WHERE level = 0),
  5000::bigint,
  'objects: level 0 entries account for every row exactly once'
);

CREATE TEMP TABLE before_rewrite AS SELECT count(*) AS n FROM pgit.nodes;

SELECT pgit.write_tree('t');

SELECT is(
  (SELECT count(*) FROM pgit.nodes),
  (SELECT n FROM before_rewrite),
  'objects: writing identical content a second time stores no new nodes'
);

CREATE TABLE twin (id int PRIMARY KEY, name text);
INSERT INTO twin SELECT g, 'row-' || g FROM generate_series(1, 5000) g;

SELECT pgit.write_tree('twin');

SELECT is(
  (SELECT count(*) FROM pgit.nodes),
  (SELECT n FROM before_rewrite),
  'objects: an identical table shares every node, storing nothing new'
);

CREATE TEMP TABLE pre_update AS SELECT hash FROM pgit.nodes WHERE level = 0;

UPDATE t SET name = 'changed' WHERE id = 2500;
SELECT pgit.write_tree('t');

SELECT ok(
  (SELECT count(*) FROM pgit.nodes WHERE level = 0
    AND hash NOT IN (SELECT hash FROM pre_update)) = 1,
  'objects: changing one row rewrites exactly one leaf node'
);

SELECT ok(
  (SELECT count(*) FROM pgit.nodes WHERE level = 0
    AND hash IN (SELECT hash FROM pre_update)) > 50,
  'objects: every other leaf node is shared unchanged'
);

SELECT * FROM finish();
ROLLBACK;
