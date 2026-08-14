BEGIN;
SELECT plan(6);

CREATE TABLE t (id int PRIMARY KEY, a text, b text, n int);
INSERT INTO t SELECT g, 'a' || g, 'b' || g, g FROM generate_series(1, 400) g;
SELECT pgit.track('t');

CREATE TEMP TABLE base_c AS SELECT pgit.commit('base', 'main') AS sha;

SELECT pgit.branch('theirs', (SELECT sha FROM base_c));

UPDATE t SET a = 'ours'  WHERE id BETWEEN 1 AND 40;
UPDATE t SET n = n + 1   WHERE id BETWEEN 100 AND 140;
UPDATE t SET a = 'both'  WHERE id BETWEEN 200 AND 210;
DELETE FROM t            WHERE id BETWEEN 300 AND 310;
INSERT INTO t SELECT g, 'ins-ours', 'x', g FROM generate_series(500, 520) g;
CREATE TEMP TABLE ours_c AS SELECT pgit.commit('ours', 'main') AS sha;

SELECT pgit.checkout('theirs');

UPDATE t SET b = 'theirs' WHERE id BETWEEN 20 AND 60;
UPDATE t SET a = 'both'   WHERE id BETWEEN 200 AND 210;
UPDATE t SET a = 'clash'  WHERE id BETWEEN 1 AND 10;
DELETE FROM t             WHERE id BETWEEN 305 AND 320;
INSERT INTO t SELECT g, 'ins-theirs', 'y', g FROM generate_series(600, 610) g;
CREATE TEMP TABLE theirs_c AS SELECT pgit.commit('theirs', 'theirs') AS sha;

CREATE TEMP TABLE roots AS
SELECT (SELECT x.root_hash FROM pgit.trees x WHERE x.commit_sha = (SELECT sha FROM base_c)   AND x.tbl = 't') AS broot,
       (SELECT x.root_hash FROM pgit.trees x WHERE x.commit_sha = (SELECT sha FROM ours_c)   AND x.tbl = 't') AS oroot,
       (SELECT x.root_hash FROM pgit.trees x WHERE x.commit_sha = (SELECT sha FROM theirs_c) AND x.tbl = 't') AS troot;

CREATE TEMP VIEW derived AS
SELECT COALESCE(dobj.k, dthr.k) AS k,
       COALESCE(dobj.b, dthr.b) AS bimg,
       CASE WHEN dobj.k IS NULL THEN dthr.b ELSE dobj.o END AS oimg,
       CASE WHEN dthr.k IS NULL THEN dobj.b ELSE dthr.t END AS timg
FROM (SELECT d.k, d.before AS b, d.after AS o
      FROM roots, LATERAL pgit.diff_tree(roots.broot, roots.oroot) d) dobj
FULL OUTER JOIN
     (SELECT d.k, d.before AS b, d.after AS t
      FROM roots, LATERAL pgit.diff_tree(roots.broot, roots.troot) d) dthr
  ON dthr.k = dobj.k;

SELECT cmp_ok((SELECT count(*) FROM derived)::int, '>', 100,
  'AC-MERGE-09: the fixture really does diverge on both sides, so the oracle is not vacuous');

SELECT is(
  (SELECT count(*) FROM derived d, roots
   WHERE d.bimg IS DISTINCT FROM (SELECT l.v FROM pgit.lookup(roots.broot, d.k) l)),
  0::bigint,
  'AC-MERGE-09: every base image taken from the diffs matches an independent tree lookup'
);

SELECT is(
  (SELECT count(*) FROM derived d, roots
   WHERE d.oimg IS DISTINCT FROM (SELECT l.v FROM pgit.lookup(roots.oroot, d.k) l)),
  0::bigint,
  'AC-MERGE-09: every ours image matches, including keys only theirs touched'
);

SELECT is(
  (SELECT count(*) FROM derived d, roots
   WHERE d.timg IS DISTINCT FROM (SELECT l.v FROM pgit.lookup(roots.troot, d.k) l)),
  0::bigint,
  'AC-MERGE-09: every theirs image matches, including keys only ours touched'
);

SELECT cmp_ok(
  (SELECT count(*) FROM pgit.merge_plan((SELECT sha FROM base_c), (SELECT sha FROM ours_c),
                                        (SELECT sha FROM theirs_c)) mp
   WHERE mp.action = 'conflict')::int, '>', 0,
  'AC-MERGE-09: the plan still finds the column that both sides changed differently'
);

SELECT is(
  (SELECT count(*) FROM pgit.merge_plan((SELECT sha FROM base_c), (SELECT sha FROM ours_c),
                                        (SELECT sha FROM theirs_c)) mp
   WHERE mp.k IN (SELECT encode(pgit.hash(convert_to('id=#' || length(g::text)::text || ':' || g || '|', 'UTF8')), 'hex')
                  FROM generate_series(200, 210) g)),
  0::bigint,
  'AC-MERGE-09: a row both sides changed to the same value needs no action at all'
);

SELECT * FROM finish();
ROLLBACK;
