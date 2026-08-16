BEGIN;
SELECT plan(6);

CREATE TABLE keep (id int PRIMARY KEY, v text);
CREATE TABLE gone (id int PRIMARY KEY, v text);
SELECT grove.track('keep');
SELECT grove.track('gone');
INSERT INTO keep SELECT g, 'k'||g FROM generate_series(1,100) g;
INSERT INTO gone SELECT g, 'g'||g FROM generate_series(1,100) g;
SELECT grove.commit('both tracked','alice');
SELECT grove.branch('side');

SELECT grove.untrack('gone');
UPDATE keep SET v = 'changed' WHERE id = 1;
SELECT grove.commit('after untrack','bob');

SELECT is((SELECT count(*) FROM grove.trees
           WHERE commit_sha = grove.resolve('side') AND tbl = 'gone'), 1::bigint,
  'untrack: the earlier commit still records the table, so a replay would reach for it');

SELECT is((SELECT count(*) FROM grove.diff_stat(grove.rev('HEAD~1'), grove.rev('HEAD'))
           WHERE tbl = 'gone' AND deleted = 100), 1::bigint,
  'untrack: and the diff reads it as every row deleted, which is what used to be applied');

SELECT grove.checkout('side', true);
SELECT is((SELECT count(*) FROM gone), 100::bigint,
  'untrack: checking out an older commit does not touch a table grove was told to stop watching');

SELECT grove.checkout('main', true);
SELECT is((SELECT count(*) FROM gone), 100::bigint,
  'untrack: and neither does checking out the commit that dropped it from the history');

SELECT is((SELECT v FROM keep WHERE id = 1), 'changed',
  'untrack: the table still tracked is still versioned');

DELETE FROM gone WHERE id <= 50;
SELECT grove.checkout('side', true);
SELECT is((SELECT count(*) FROM gone), 50::bigint,
  'untrack: grove does not restore it either, an untracked table is simply not its business');

SELECT * FROM finish();
ROLLBACK;
