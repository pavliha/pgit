BEGIN;
SELECT plan(4);

CREATE TABLE au (id int PRIMARY KEY, v text NOT NULL);
INSERT INTO au SELECT g, 'v' || g FROM generate_series(1, 300) g;
SELECT pgit.track('au');
SELECT pgit.commit('base');

SELECT pgit.branch('f1');
SELECT pgit.checkout('f1');
UPDATE au SET v = 'f1' WHERE id = 1;
SELECT pgit.commit('on f1');

SELECT pgit.branch('f2', pgit.resolve('main'));
SELECT pgit.checkout('f2');
UPDATE au SET v = 'f2' WHERE id = 2;
SELECT pgit.commit('on f2');

SELECT pgit.checkout('main');
SELECT pgit.cherry_pick(pgit.resolve('f1'), 'picked f1');
SELECT pgit.revert(pgit.resolve('main'));
SELECT pgit.merge_octopus(ARRAY['f1', 'f2'], 'octopus');

SELECT pgit.checkout('f2');
SELECT pgit.rebase('main');

SELECT cmp_ok(
  (SELECT count(*)::int FROM pgit.commits), '>=', 6,
  'AC-OBS-04: the workflow created commits through commit, cherry_pick, revert, octopus and rebase');

SELECT is(
  (SELECT count(*)::int FROM pgit.commits),
  (SELECT count(*)::int FROM pgit.events
   WHERE verb IN ('commit', 'cherry_pick', 'merge_finish', 'merge_octopus')),
  'AC-OBS-04: every commit in the database was recorded by an event, whatever verb built it');

SELECT ok(
  EXISTS (SELECT 1 FROM pgit.events WHERE verb = 'rebase'),
  'AC-OBS-04: and a rebase is on the record, which is the event an audit most needs');

SELECT ok(
  NOT (SELECT (e.detail ->> 'rewritten')::boolean FROM pgit.events e WHERE e.verb = 'rebase'),
  'AC-OBS-04: a rebase that fast forwarded does not claim to have rewritten anything');

SELECT * FROM finish();
ROLLBACK;
