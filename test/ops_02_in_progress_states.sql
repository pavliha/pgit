BEGIN;
SELECT plan(6);

CREATE TABLE st (id int PRIMARY KEY, v text NOT NULL);
INSERT INTO st VALUES (1, 'a'), (2, 'b');
SELECT grove.track('st');
SELECT grove.commit('base');

SELECT is(
  (SELECT count(*)::int FROM grove.needs_attention()), 0,
  'AC-OPS-02: a settled repository wants no attention');

SELECT grove.branch('l');
SELECT grove.branch('r');
SELECT grove.checkout('l');
UPDATE st SET v = 'left' WHERE id = 1;
SELECT grove.commit('left edit');
SELECT grove.checkout('r');
UPDATE st SET v = 'right' WHERE id = 1;
SELECT grove.commit('right edit');
SELECT grove.merge('l', 'merge l');

SELECT is(
  (SELECT count(*)::int FROM grove.merges), 1,
  'AC-OPS-02: the conflicted merge is parked, waiting for a human');

SELECT ok(
  EXISTS (SELECT 1 FROM grove.needs_attention() WHERE metric = 'merge in progress'),
  'AC-OPS-02: and needs_attention says so, so a monitor cannot report green while stuck');

SELECT ok(
  EXISTS (SELECT 1 FROM grove.needs_attention() WHERE metric = 'conflicts awaiting resolution'),
  'AC-OPS-02: naming the unresolved conflicts alongside it');

SELECT grove.resolve_conflict(
  (SELECT id FROM grove.merges LIMIT 1), 'st',
  (SELECT k FROM grove.conflicts WHERE NOT resolved LIMIT 1), 'theirs');
SELECT grove.merge_finish((SELECT id FROM grove.merges LIMIT 1));

SELECT is(
  (SELECT count(*)::int FROM grove.needs_attention()), 0,
  'AC-OPS-02: finishing the merge puts it back to green');

SELECT grove.bisect_start('HEAD~1', 'HEAD');

SELECT ok(
  EXISTS (SELECT 1 FROM grove.needs_attention() WHERE metric = 'bisect in progress'),
  'AC-OPS-02: an abandoned bisect is visible too, not silent state left behind');

SELECT * FROM finish();
ROLLBACK;
