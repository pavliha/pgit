BEGIN;
SELECT plan(4);

CREATE TABLE au (id int PRIMARY KEY, v text NOT NULL);
INSERT INTO au SELECT g, 'v' || g FROM generate_series(1, 300) g;
SELECT grove.track('au');
SELECT grove.commit('base');

SELECT grove.branch('f1');
SELECT grove.checkout('f1');
UPDATE au SET v = 'f1' WHERE id = 1;
SELECT grove.commit('on f1');

SELECT grove.branch('f2', grove.resolve('main'));
SELECT grove.checkout('f2');
UPDATE au SET v = 'f2' WHERE id = 2;
SELECT grove.commit('on f2');

SELECT grove.checkout('main');
SELECT grove.cherry_pick(grove.resolve('f1'), 'picked f1');
SELECT grove.revert(grove.resolve('main'));
SELECT grove.merge_octopus(ARRAY['f1', 'f2'], 'octopus');

SELECT grove.checkout('f2');
SELECT grove.rebase('main');

SELECT cmp_ok(
  (SELECT count(*)::int FROM grove.commits), '>=', 6,
  'AC-OBS-04: the workflow created commits through commit, cherry_pick, revert, octopus and rebase');

SELECT is(
  (SELECT count(*)::int FROM grove.commits),
  (SELECT count(*)::int FROM grove.events
   WHERE verb IN ('commit', 'cherry_pick', 'merge_finish', 'merge_octopus')),
  'AC-OBS-04: every commit in the database was recorded by an event, whatever verb built it');

SELECT ok(
  EXISTS (SELECT 1 FROM grove.events WHERE verb = 'rebase'),
  'AC-OBS-04: and a rebase is on the record, which is the event an audit most needs');

SELECT ok(
  NOT (SELECT (e.detail ->> 'rewritten')::boolean FROM grove.events e WHERE e.verb = 'rebase'),
  'AC-OBS-04: a rebase that fast forwarded does not claim to have rewritten anything');

SELECT * FROM finish();
ROLLBACK;
