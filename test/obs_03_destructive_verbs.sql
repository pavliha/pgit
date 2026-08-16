BEGIN;
SELECT plan(6);

CREATE TABLE dv (id int PRIMARY KEY, x text NOT NULL);
INSERT INTO dv SELECT g, 'v' || g FROM generate_series(1, 200) g;
SELECT grove.track('dv');
SELECT grove.commit('base');

UPDATE dv SET x = 'bad' WHERE id = 1;
SELECT grove.commit('a bad change');
SELECT grove.revert(grove.resolve('main'));

SELECT is(
  (SELECT e.detail ->> 'rows' FROM grove.events e WHERE e.verb = 'revert'), '1',
  'AC-OBS-05: a revert is recorded as a revert, not just as the commit it produced');

SELECT grove.branch('l');
SELECT grove.branch('r');
SELECT grove.checkout('l');
UPDATE dv SET x = 'L' WHERE id = 2;
SELECT grove.commit('l');
SELECT grove.checkout('r');
UPDATE dv SET x = 'R' WHERE id = 2;
SELECT grove.commit('r');
SELECT grove.merge('l', 'conflicting');

SELECT grove.resolve_conflict(
  (SELECT id FROM grove.merges LIMIT 1), 'dv',
  (SELECT k FROM grove.conflicts WHERE NOT resolved LIMIT 1), 'theirs');

SELECT is(
  (SELECT e.detail ->> 'kind' FROM grove.events e WHERE e.verb = 'resolve_conflict'), 'theirs',
  'AC-OBS-05: resolving a conflict records which side won, which is the decision an audit asks about');

SELECT grove.merge_abort((SELECT id FROM grove.merges LIMIT 1));

SELECT is(
  (SELECT e.detail ->> 'discarded_conflicts' FROM grove.events e WHERE e.verb = 'merge_abort'), '1',
  'AC-OBS-05: aborting a merge records how much resolved work it threw away');

SELECT ok(
  NOT (SELECT e.ok FROM grove.events e WHERE e.verb = 'merge_abort'),
  'AC-OBS-05: and marks it not ok, so throwing work away shows up in grove_events_failed');

SELECT grove.tag('rel');
SELECT grove.tag_delete('rel');

SELECT ok(
  EXISTS (SELECT 1 FROM grove.events WHERE verb = 'tag_delete' AND detail ? 'was'),
  'AC-OBS-05: deleting a tag records the commit it used to point at');

SELECT grove.reset('HEAD~1', 'hard');

SELECT ok(
  EXISTS (SELECT 1 FROM grove.events WHERE verb = 'reset' AND detail ->> 'mode' = 'hard'),
  'AC-OBS-05: a hard reset, which can abandon commits, is never silent');

SELECT * FROM finish();
ROLLBACK;
