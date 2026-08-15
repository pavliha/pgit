BEGIN;
SELECT plan(10);

CREATE FUNCTION brute_diff(a bytea, b bytea)
RETURNS TABLE (k text, op text, before jsonb, after jsonb)
LANGUAGE sql STABLE AS $fn$
  SELECT COALESCE(la.k, lb.k),
         CASE WHEN la.k IS NULL THEN 'INSERT'
              WHEN lb.k IS NULL THEN 'DELETE'
              ELSE 'UPDATE' END,
         la.v, lb.v
  FROM pgit.leaves(a) la FULL OUTER JOIN pgit.leaves(b) lb ON la.k = lb.k
  WHERE la.rh IS DISTINCT FROM lb.rh
$fn$;

CREATE FUNCTION agrees(a bytea, b bytea) RETURNS bigint
LANGUAGE sql STABLE AS $fn$
  SELECT (SELECT count(*) FROM (
            SELECT * FROM pgit.diff_tree(a, b)
            EXCEPT ALL SELECT * FROM brute_diff(a, b)) q)
       + (SELECT count(*) FROM (
            SELECT * FROM brute_diff(a, b)
            EXCEPT ALL SELECT * FROM pgit.diff_tree(a, b)) q)
$fn$;

CREATE TABLE t (id int PRIMARY KEY, v text);
SELECT pgit.track('t');
INSERT INTO t SELECT g * 10, 'v' || g FROM generate_series(1, 5000) g;
SELECT pgit.commit('base', 'p');
CREATE TEMP TABLE c0 AS
SELECT root_hash AS root FROM pgit.trees
WHERE commit_sha = pgit.resolve('main') AND tbl = 't';

SELECT cmp_ok((SELECT count(*) FROM pgit.nodes_at_level((SELECT root FROM c0), 0)), '>', 20::bigint,
  'oracle: the tree has many chunks, so boundaries have somewhere to move');

INSERT INTO t SELECT g * 10 + 1, 'inserted' || g FROM generate_series(1, 5000) g;
SELECT pgit.commit('interleave', 'p');
CREATE TEMP TABLE c1 AS
SELECT root_hash AS root FROM pgit.trees
WHERE commit_sha = pgit.resolve('main') AND tbl = 't';

SELECT is(agrees((SELECT root FROM c0), (SELECT root FROM c1)), 0::bigint,
  'oracle: interleaving 5000 keys agrees with a full scan of both trees');
SELECT is((SELECT count(*) FROM pgit.diff_tree((SELECT root FROM c0), (SELECT root FROM c1))),
  5000::bigint, 'oracle: and it reports every inserted row');

UPDATE t SET v = v || '-x' WHERE id % 730 = 0;
SELECT pgit.commit('scattered update', 'p');
CREATE TEMP TABLE c2 AS
SELECT root_hash AS root FROM pgit.trees
WHERE commit_sha = pgit.resolve('main') AND tbl = 't';

SELECT is(agrees((SELECT root FROM c1), (SELECT root FROM c2)), 0::bigint,
  'oracle: a scattered update agrees');

DELETE FROM t WHERE id BETWEEN 20000 AND 30000;
SELECT pgit.commit('range delete', 'p');
CREATE TEMP TABLE c3 AS
SELECT root_hash AS root FROM pgit.trees
WHERE commit_sha = pgit.resolve('main') AND tbl = 't';

SELECT is(agrees((SELECT root FROM c2), (SELECT root FROM c3)), 0::bigint,
  'oracle: deleting a contiguous range agrees');
SELECT is(agrees((SELECT root FROM c0), (SELECT root FROM c3)), 0::bigint,
  'oracle: and so does the whole range, three commits apart');

INSERT INTO t SELECT g, 'mixed' || g FROM generate_series(500000, 502000) g;
UPDATE t SET v = 'touched' WHERE id % 1301 = 0;
DELETE FROM t WHERE id % 1699 = 0;
SELECT pgit.commit('mixed', 'p');
CREATE TEMP TABLE c4 AS
SELECT root_hash AS root FROM pgit.trees
WHERE commit_sha = pgit.resolve('main') AND tbl = 't';

SELECT is(agrees((SELECT root FROM c3), (SELECT root FROM c4)), 0::bigint,
  'oracle: insert, update and delete in one commit agrees');

SELECT is(agrees((SELECT root FROM c4), (SELECT root FROM c4)), 0::bigint,
  'oracle: a tree against itself agrees, and reports nothing');
SELECT is((SELECT count(*) FROM pgit.diff_tree((SELECT root FROM c4), (SELECT root FROM c4))),
  0::bigint, 'oracle: identical roots really do produce an empty diff');

SELECT is(agrees((SELECT root FROM c4), (SELECT root FROM c0)), 0::bigint,
  'oracle: the diff agrees when run backwards too');

SELECT * FROM finish();
ROLLBACK;
