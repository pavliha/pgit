BEGIN;
SELECT plan(12);

CREATE TABLE t (id int PRIMARY KEY, a text, c text);
SELECT grove.track('t');
INSERT INTO t VALUES (1, 'one', 'payload-1'), (2, 'two', 'payload-2');
SELECT grove.commit('wide', 'pavlo');
SELECT set_config('probe.wide', encode(grove.resolve(grove.head()), 'hex'), false);

ALTER TABLE t DROP COLUMN c;
SELECT grove.commit('narrow', 'pavlo');
SELECT set_config('probe.narrow', encode(grove.resolve(grove.head()), 'hex'), false);

SELECT throws_like(
  $$ SELECT grove.reset(current_setting('probe.wide'), 'hard') $$,
  '%different shape%',
  'AC-DDL: reset --hard refuses a commit whose shape no longer matches the table');

SELECT throws_like(
  $$ SELECT grove.reset(current_setting('probe.wide'), 'hard') $$,
  '%reset --hard restores data but not shape%',
  'AC-DDL: and it names itself, rather than blaming checkout');

SELECT throws_like(
  $$ SELECT grove.restore(current_setting('probe.wide'), 't') $$,
  '%restore restores data but not shape%',
  'AC-DDL: restore refuses the same commit, it used to drop the missing column silently');

SELECT lives_ok(
  $$ SELECT grove.reset(current_setting('probe.wide'), 'soft') $$,
  'AC-DDL: a soft reset is still allowed, it moves the ref and writes no rows');

SELECT grove.reset(current_setting('probe.narrow'), 'soft');

ALTER TABLE t ADD COLUMN c text;
UPDATE t SET c = 'restored-' || id;
SELECT grove.commit('wide again', 'pavlo');

SELECT lives_ok(
  $$ SELECT grove.reset(current_setting('probe.wide'), 'hard') $$,
  'AC-DDL: and once the shape matches again the hard reset goes through');

SELECT is(grove.is_dirty(), false,
  'AC-DDL: a hard reset that reports success leaves nothing dirty behind');

UPDATE t SET c = 'stashed-' || id;
SELECT grove.stash_push('wip');
ALTER TABLE t DROP COLUMN c;

SELECT throws_like(
  $$ SELECT grove.stash_pop() $$,
  '%stash pop restores data but not shape%',
  'AC-DDL: stash pop refuses when the column it stashed is gone');

SELECT is((SELECT count(*)::int FROM grove.stash_list()), 1,
  'AC-DDL: and the refusal keeps the stash, which used to be dropped with the data still in it');

ALTER TABLE t ADD COLUMN c text;

SELECT lives_ok(
  $$ SELECT grove.stash_pop() $$,
  'AC-DDL: put the column back and the same stash pops cleanly');

SELECT grove.untrack('t');
DROP TABLE t;

CREATE TABLE u (id int PRIMARY KEY, name text, extra text);
SELECT grove.track('u');
INSERT INTO u VALUES (1, 'one', 'keep1'), (2, 'two', 'keep2');
SELECT grove.commit('u base', 'pavlo');
SELECT grove.branch('feature');
UPDATE u SET name = 'main version' WHERE id = 2;
SELECT grove.commit('main edits row 2', 'pavlo');
SELECT grove.checkout('feature');
UPDATE u SET name = 'feature version' WHERE id = 2;
SELECT grove.commit('feature edits row 2', 'pavlo');
SELECT grove.rebase('main');

ALTER TABLE u DROP COLUMN extra;

SELECT throws_like(
  $$ SELECT grove.rebase_abort() $$,
  '%rebase abort restores data but not shape%',
  'AC-DDL: aborting a parked rebase refuses once a column it would restore is gone');

SELECT is((SELECT count(*)::int FROM grove.rebase_state), 1,
  'AC-DDL: and the refusal keeps the parked rebase, which used to be cleared on the way out');

ALTER TABLE u ADD COLUMN extra text;

SELECT lives_ok(
  $$ SELECT grove.rebase_abort() $$,
  'AC-DDL: put the column back and the same abort goes through');

SELECT * FROM finish();
ROLLBACK;
