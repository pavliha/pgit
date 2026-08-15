BEGIN;
SELECT plan(6);

CREATE TABLE dv (id int PRIMARY KEY, x text NOT NULL);
INSERT INTO dv SELECT g, 'v' || g FROM generate_series(1, 200) g;
SELECT pgit.track('dv');
SELECT pgit.commit('base');

UPDATE dv SET x = 'bad' WHERE id = 1;
SELECT pgit.commit('a bad change');
SELECT pgit.revert(pgit.resolve('main'));

SELECT is(
  (SELECT e.detail ->> 'rows' FROM pgit.events e WHERE e.verb = 'revert'), '1',
  'AC-OBS-05: a revert is recorded as a revert, not just as the commit it produced');

SELECT pgit.branch('l');
SELECT pgit.branch('r');
SELECT pgit.checkout('l');
UPDATE dv SET x = 'L' WHERE id = 2;
SELECT pgit.commit('l');
SELECT pgit.checkout('r');
UPDATE dv SET x = 'R' WHERE id = 2;
SELECT pgit.commit('r');
SELECT pgit.merge('l', 'conflicting');

SELECT pgit.resolve_conflict(
  (SELECT id FROM pgit.merges LIMIT 1), 'dv',
  (SELECT k FROM pgit.conflicts WHERE NOT resolved LIMIT 1), 'theirs');

SELECT is(
  (SELECT e.detail ->> 'kind' FROM pgit.events e WHERE e.verb = 'resolve_conflict'), 'theirs',
  'AC-OBS-05: resolving a conflict records which side won, which is the decision an audit asks about');

SELECT pgit.merge_abort((SELECT id FROM pgit.merges LIMIT 1));

SELECT is(
  (SELECT e.detail ->> 'discarded_conflicts' FROM pgit.events e WHERE e.verb = 'merge_abort'), '1',
  'AC-OBS-05: aborting a merge records how much resolved work it threw away');

SELECT ok(
  NOT (SELECT e.ok FROM pgit.events e WHERE e.verb = 'merge_abort'),
  'AC-OBS-05: and marks it not ok, so throwing work away shows up in pgit_events_failed');

SELECT pgit.tag('rel');
SELECT pgit.tag_delete('rel');

SELECT ok(
  EXISTS (SELECT 1 FROM pgit.events WHERE verb = 'tag_delete' AND detail ? 'was'),
  'AC-OBS-05: deleting a tag records the commit it used to point at');

SELECT pgit.reset('HEAD~1', 'hard');

SELECT ok(
  EXISTS (SELECT 1 FROM pgit.events WHERE verb = 'reset' AND detail ->> 'mode' = 'hard'),
  'AC-OBS-05: a hard reset, which can abandon commits, is never silent');

SELECT * FROM finish();
ROLLBACK;
