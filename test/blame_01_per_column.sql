BEGIN;
SELECT plan(8);

CREATE TABLE t (id int PRIMARY KEY, name text, hits int, note text);
SELECT pgit.track('t');

SET LOCAL pgit.actor = 'creator';
INSERT INTO t VALUES (1, 'original', 0, NULL);
CREATE TEMP TABLE c1 AS SELECT pgit.commit('create', 'creator') AS sha;

SELECT is(
  (SELECT count(*) FROM pgit.blame('t', '1')), 4::bigint,
  'AC-BLAME-02: a freshly created row attributes every column, including the NULL one'
);

SELECT is(
  (SELECT count(DISTINCT commit_sha) FROM pgit.blame('t', '1')), 1::bigint,
  'AC-BLAME-02: every column points at the creating commit'
);

SET LOCAL pgit.actor = 'renamer';
UPDATE t SET name = 'renamed' WHERE id = 1;
CREATE TEMP TABLE c2 AS SELECT pgit.commit('rename', 'renamer') AS sha;

SET LOCAL pgit.actor = 'counter';
UPDATE t SET hits = 42 WHERE id = 1;
CREATE TEMP TABLE c3 AS SELECT pgit.commit('count', 'counter') AS sha;

SELECT is(
  (SELECT commit_sha FROM pgit.blame('t', '1') WHERE col = 'name'),
  (SELECT sha FROM c2), 'AC-BLAME-01: the name column points at the commit that renamed it'
);

SELECT is(
  (SELECT commit_sha FROM pgit.blame('t', '1') WHERE col = 'hits'),
  (SELECT sha FROM c3), 'AC-BLAME-01: the hits column points at the commit that set it'
);

SELECT is(
  (SELECT commit_sha FROM pgit.blame('t', '1') WHERE col = 'note'),
  (SELECT sha FROM c1), 'AC-BLAME-01: an untouched column still points at the creating commit'
);

SELECT is(
  (SELECT actor FROM pgit.blame('t', '1') WHERE col = 'hits'),
  'counter', 'AC-BLAME-01: blame reports who changed each column'
);

SELECT is(
  (SELECT value FROM pgit.blame('t', '1') WHERE col = 'name'),
  '"renamed"'::jsonb, 'AC-BLAME-01: blame reports the current value of each column'
);

UPDATE t SET name = 'original' WHERE id = 1;
CREATE TEMP TABLE c4 AS SELECT pgit.commit('restore the old name', 'restorer') AS sha;

SELECT is(
  (SELECT commit_sha FROM pgit.blame('t', '1') WHERE col = 'name'),
  (SELECT sha FROM c4),
  'AC-BLAME-01: setting a column back to an earlier value blames the latest writer, not the value'
);

SELECT * FROM finish();
ROLLBACK;
