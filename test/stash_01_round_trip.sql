BEGIN;
SELECT plan(7);

CREATE TABLE st (id int PRIMARY KEY, name text NOT NULL);
INSERT INTO st SELECT g, 'committed ' || g FROM generate_series(1, 200) g;
SELECT grove.track('st');
SELECT grove.commit('base');

UPDATE st SET name = 'work in progress' WHERE id = 1;

SELECT isnt(
  grove.stash_push('wip'), NULL,
  'AC-STASH-01: stashing uncommitted work returns the slot it went into');

SELECT ok(
  NOT grove.is_dirty(),
  'AC-STASH-01: and leaves the working tree clean');

SELECT is(
  (SELECT name FROM st WHERE id = 1), 'committed 1',
  'AC-STASH-01: the row is back to what the last commit recorded');

SELECT is(
  (SELECT count(*)::int FROM grove.stash_list()), 1,
  'AC-STASH-01: the stash list shows exactly what was put aside');

SELECT grove.stash_pop();

SELECT is(
  (SELECT name FROM st WHERE id = 1), 'work in progress',
  'AC-STASH-01: popping brings the uncommitted work back');

SELECT is(
  (SELECT count(*)::int FROM grove.stash_list()), 0,
  'AC-STASH-01: and takes it off the list');

SELECT throws_ok(
  $$ SELECT grove.stash_pop() $$,
  NULL, NULL,
  'AC-STASH-01: popping an empty stash is refused rather than silently doing nothing');

SELECT * FROM finish();
ROLLBACK;
