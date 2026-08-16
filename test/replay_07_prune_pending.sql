BEGIN;
SELECT plan(5);

CREATE TABLE pp (id int PRIMARY KEY, v text);
SELECT grove.track('pp');
INSERT INTO pp SELECT g, 'v' || g FROM generate_series(1, 2000) g;
SELECT grove.commit('pp base', 'main');

UPDATE pp SET v = 'CHANGED' WHERE id <= 100;

SELECT is(
  (SELECT count(*)::int FROM grove.changes WHERE commit_sha IS NULL), 100,
  'AC-REPLAY-07: an uncommitted update is pending in the journal');

SELECT is(
  grove.prune(now() - interval '100 years'), 0,
  'AC-REPLAY-07: pruning with a cutoff older than everything removes no commit');

SELECT is(
  (SELECT count(*)::int FROM grove.changes WHERE commit_sha IS NULL), 100,
  'AC-REPLAY-07: and leaves the pending work alone - NULL commit_sha means not yet committed, not garbage');

SELECT grove.commit('after prune', 'main');

SELECT is(
  grove.write_tree('pp'),
  (SELECT root_hash FROM grove.trees WHERE commit_sha = grove.resolve('main') AND tbl = 'pp'),
  'AC-REPLAY-07: so the commit after a prune still records what the table holds');

SELECT is(
  (SELECT count(*)::int FROM pp WHERE v = 'CHANGED'), 100,
  'AC-REPLAY-07: and the rows themselves were never touched');

SELECT * FROM finish();
ROLLBACK;
