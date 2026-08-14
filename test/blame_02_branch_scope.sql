BEGIN;
SELECT plan(7);

CREATE TABLE t (id int PRIMARY KEY, v text, hits int);
SELECT pgit.track('t');
INSERT INTO t VALUES (1, 'base', 0), (2, 'base', 0);
SELECT pgit.commit('base', 'alice');

UPDATE t SET v = 'on main' WHERE id = 1;
SELECT pgit.commit('main edit', 'alice');

SELECT is((SELECT value #>> '{}' FROM pgit.blame('t', '1') WHERE col = 'v'), 'on main',
  'blame: the value on main is the one main set');

SELECT pgit.branch('side');
SELECT pgit.checkout('side');
UPDATE t SET v = 'on side' WHERE id = 1;
SELECT pgit.commit('side edit', 'bob');

SELECT is((SELECT value #>> '{}' FROM pgit.blame('t', '1') WHERE col = 'v'), 'on side',
  'blame: standing on the side branch reports the side value');

SELECT pgit.checkout('main');

SELECT is((SELECT value #>> '{}' FROM pgit.blame('t', '1') WHERE col = 'v'), 'on main',
  'blame: back on main, a change made only on side is not attributed');

SELECT is(
  (SELECT pgit.short_sha(commit_sha) FROM pgit.blame('t', '1') WHERE col = 'v'),
  (SELECT pgit.short_sha(pgit.resolve('main'))),
  'blame: and it points at the commit on this branch, not the side one');

SELECT pgit.checkout('side');
DELETE FROM t WHERE id = 2;
SELECT pgit.commit('side deletes a row', 'bob');
SELECT pgit.checkout('main');

SELECT is((SELECT value #>> '{}' FROM pgit.blame('t', '2') WHERE col = 'v'), 'base',
  'blame: a row deleted only on another branch still blames to its live value here');

SELECT ok(
  (SELECT count(*) FROM pgit.blame('t', '2') WHERE value IS NOT NULL) > 0,
  'blame: that row reports real values, not the nulls a foreign delete would leave');

SELECT pgit.merge('side');

SELECT is((SELECT value #>> '{}' FROM pgit.blame('t', '1') WHERE col = 'v'), 'on side',
  'blame: once side is merged in, its change is attributed on main');

SELECT * FROM finish();
ROLLBACK;
