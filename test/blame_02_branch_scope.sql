BEGIN;
SELECT plan(7);

CREATE TABLE t (id int PRIMARY KEY, v text, hits int);
SELECT grove.track('t');
INSERT INTO t VALUES (1, 'base', 0), (2, 'base', 0);
SELECT grove.commit('base', 'alice');

UPDATE t SET v = 'on main' WHERE id = 1;
SELECT grove.commit('main edit', 'alice');

SELECT is((SELECT value #>> '{}' FROM grove.blame('t', '1') WHERE col = 'v'), 'on main',
  'blame: the value on main is the one main set');

SELECT grove.branch('side');
SELECT grove.checkout('side');
UPDATE t SET v = 'on side' WHERE id = 1;
SELECT grove.commit('side edit', 'bob');

SELECT is((SELECT value #>> '{}' FROM grove.blame('t', '1') WHERE col = 'v'), 'on side',
  'blame: standing on the side branch reports the side value');

SELECT grove.checkout('main');

SELECT is((SELECT value #>> '{}' FROM grove.blame('t', '1') WHERE col = 'v'), 'on main',
  'blame: back on main, a change made only on side is not attributed');

SELECT is(
  (SELECT grove.short_sha(commit_sha) FROM grove.blame('t', '1') WHERE col = 'v'),
  (SELECT grove.short_sha(grove.resolve('main'))),
  'blame: and it points at the commit on this branch, not the side one');

SELECT grove.checkout('side');
DELETE FROM t WHERE id = 2;
SELECT grove.commit('side deletes a row', 'bob');
SELECT grove.checkout('main');

SELECT is((SELECT value #>> '{}' FROM grove.blame('t', '2') WHERE col = 'v'), 'base',
  'blame: a row deleted only on another branch still blames to its live value here');

SELECT ok(
  (SELECT count(*) FROM grove.blame('t', '2') WHERE value IS NOT NULL) > 0,
  'blame: that row reports real values, not the nulls a foreign delete would leave');

SELECT grove.merge('side');

SELECT is((SELECT value #>> '{}' FROM grove.blame('t', '1') WHERE col = 'v'), 'on side',
  'blame: once side is merged in, its change is attributed on main');

SELECT * FROM finish();
ROLLBACK;
