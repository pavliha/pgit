BEGIN;
SELECT plan(7);

CREATE TABLE t (id int PRIMARY KEY, a text, b text, c text);
SELECT pgit.track('t');
INSERT INTO t VALUES (1,'base','base','base');
SELECT pgit.commit('A','p');

SELECT pgit.branch('feature');

UPDATE t SET a='from main' WHERE id=1;
SELECT pgit.commit('B','p');
SELECT pgit.branch('bmark');

SELECT pgit.checkout('feature');
UPDATE t SET b='from feature' WHERE id=1;
SELECT pgit.commit('C','p');
SELECT pgit.branch('cmark');

SELECT pgit.checkout('main');
SELECT is(pgit.merge('cmark'), 0, 'crisscross: main merges the feature tip');
SELECT is((SELECT a||'/'||b FROM t WHERE id=1), 'from main/from feature',
  'crisscross: the first merge combined both edits');

SELECT pgit.checkout('feature');
SELECT is(pgit.merge('bmark'), 0, 'crisscross: feature independently merges the main tip');

CREATE TEMP TABLE bases AS
SELECT (SELECT count(*) FROM (
  SELECT x.a AS s FROM pgit.ancestors(pgit.resolve('main')) x
  INTERSECT
  SELECT y.a FROM pgit.ancestors(pgit.resolve('feature')) y) c
  WHERE NOT EXISTS (
    SELECT 1 FROM (
      SELECT x2.a AS s2 FROM pgit.ancestors(pgit.resolve('main')) x2
      INTERSECT
      SELECT y2.a FROM pgit.ancestors(pgit.resolve('feature')) y2) c2
    WHERE c2.s2 <> c.s AND c.s IN (SELECT z.a FROM pgit.ancestors(c2.s2) z))) AS n;

SELECT is((SELECT n FROM bases), 2::bigint,
  'crisscross: the two branches genuinely have two merge bases');

CREATE TEMP TABLE vb AS SELECT pgit.merge_base(pgit.resolve('feature'), pgit.resolve('main')) AS sha;

SELECT ok(
  NOT EXISTS (SELECT 1 FROM pgit.commits WHERE sha = (SELECT sha FROM vb)),
  'crisscross: merge_base returned a synthesised virtual base, not a real commit');

SELECT ok(
  EXISTS (SELECT 1 FROM pgit.trees WHERE commit_sha = (SELECT sha FROM vb)),
  'crisscross: the virtual base has real trees the merge can diff against');

UPDATE t SET c='third edit' WHERE id=1;
SELECT pgit.commit('D','p');

SELECT is(pgit.merge('main'), 0,
  'crisscross: merging across a criss-cross completes instead of refusing');

SELECT * FROM finish();
ROLLBACK;
