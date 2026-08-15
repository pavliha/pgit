BEGIN;
SELECT plan(6);

CREATE TABLE st (id int PRIMARY KEY, v text NOT NULL);
INSERT INTO st VALUES (1, 'a'), (2, 'b');
SELECT pgit.track('st');
SELECT pgit.commit('base');

SELECT is(
  (SELECT count(*)::int FROM pgit.needs_attention()), 0,
  'AC-OPS-02: a settled repository wants no attention');

SELECT pgit.branch('l');
SELECT pgit.branch('r');
SELECT pgit.checkout('l');
UPDATE st SET v = 'left' WHERE id = 1;
SELECT pgit.commit('left edit');
SELECT pgit.checkout('r');
UPDATE st SET v = 'right' WHERE id = 1;
SELECT pgit.commit('right edit');
SELECT pgit.merge('l', 'merge l');

SELECT is(
  (SELECT count(*)::int FROM pgit.merges), 1,
  'AC-OPS-02: the conflicted merge is parked, waiting for a human');

SELECT ok(
  EXISTS (SELECT 1 FROM pgit.needs_attention() WHERE metric = 'merge in progress'),
  'AC-OPS-02: and needs_attention says so, so a monitor cannot report green while stuck');

SELECT ok(
  EXISTS (SELECT 1 FROM pgit.needs_attention() WHERE metric = 'conflicts awaiting resolution'),
  'AC-OPS-02: naming the unresolved conflicts alongside it');

SELECT pgit.resolve_conflict(
  (SELECT id FROM pgit.merges LIMIT 1), 'st',
  (SELECT k FROM pgit.conflicts WHERE NOT resolved LIMIT 1), 'theirs');
SELECT pgit.merge_finish((SELECT id FROM pgit.merges LIMIT 1));

SELECT is(
  (SELECT count(*)::int FROM pgit.needs_attention()), 0,
  'AC-OPS-02: finishing the merge puts it back to green');

SELECT pgit.bisect_start('HEAD~1', 'HEAD');

SELECT ok(
  EXISTS (SELECT 1 FROM pgit.needs_attention() WHERE metric = 'bisect in progress'),
  'AC-OPS-02: an abandoned bisect is visible too, not silent state left behind');

SELECT * FROM finish();
ROLLBACK;
