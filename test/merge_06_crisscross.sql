BEGIN;
SELECT plan(7);

CREATE TABLE t (id int PRIMARY KEY, a text, b text, c text);
SELECT grove.track('t');
INSERT INTO t VALUES (1,'base','base','base');
SELECT grove.commit('A','p');

SELECT grove.branch('feature');

UPDATE t SET a='from main' WHERE id=1;
SELECT grove.commit('B','p');
SELECT grove.branch('bmark');

SELECT grove.checkout('feature');
UPDATE t SET b='from feature' WHERE id=1;
SELECT grove.commit('C','p');
SELECT grove.branch('cmark');

SELECT grove.checkout('main');
SELECT is(grove.merge('cmark'), 0, 'crisscross: main merges the feature tip');
SELECT is((SELECT a||'/'||b FROM t WHERE id=1), 'from main/from feature',
  'crisscross: the first merge combined both edits');

SELECT grove.checkout('feature');
SELECT is(grove.merge('bmark'), 0, 'crisscross: feature independently merges the main tip');

CREATE TEMP TABLE bases AS
SELECT (SELECT count(*) FROM (
  SELECT x.a AS s FROM grove.ancestors(grove.resolve('main')) x
  INTERSECT
  SELECT y.a FROM grove.ancestors(grove.resolve('feature')) y) c
  WHERE NOT EXISTS (
    SELECT 1 FROM (
      SELECT x2.a AS s2 FROM grove.ancestors(grove.resolve('main')) x2
      INTERSECT
      SELECT y2.a FROM grove.ancestors(grove.resolve('feature')) y2) c2
    WHERE c2.s2 <> c.s AND c.s IN (SELECT z.a FROM grove.ancestors(c2.s2) z))) AS n;

SELECT is((SELECT n FROM bases), 2::bigint,
  'crisscross: the two branches genuinely have two merge bases');

CREATE TEMP TABLE vb AS SELECT grove.merge_base(grove.resolve('feature'), grove.resolve('main')) AS sha;

SELECT ok(
  NOT EXISTS (SELECT 1 FROM grove.commits WHERE sha = (SELECT sha FROM vb)),
  'crisscross: merge_base returned a synthesised virtual base, not a real commit');

SELECT ok(
  EXISTS (SELECT 1 FROM grove.trees WHERE commit_sha = (SELECT sha FROM vb)),
  'crisscross: the virtual base has real trees the merge can diff against');

UPDATE t SET c='third edit' WHERE id=1;
SELECT grove.commit('D','p');

SELECT is(grove.merge('main'), 0,
  'crisscross: merging across a criss-cross completes instead of refusing');

SELECT * FROM finish();
ROLLBACK;
