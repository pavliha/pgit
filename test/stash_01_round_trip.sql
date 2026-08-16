BEGIN;
SELECT plan(14);

CREATE TABLE st (id int PRIMARY KEY, name text NOT NULL);
INSERT INTO st SELECT g, 'committed ' || g FROM generate_series(1, 200) g;
SELECT grove.track('st');
SELECT grove.commit('base');

UPDATE st SET name = 'work in progress' WHERE id = 1;
INSERT INTO st VALUES (9999, 'added but not committed');

SELECT cmp_ok((SELECT count(*) FROM grove.changes WHERE commit_sha IS NULL), '>', 0::bigint,
  'AC-STASH-01: the journal is holding the uncommitted work before it is stashed');

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

SELECT is((SELECT count(*) FROM grove.changes WHERE commit_sha IS NULL), 0::bigint,
  'AC-STASH-01: and the journal is empty again, the work is in the stash and not pending');
SELECT is((SELECT count(*) FROM st WHERE id = 9999), 0::bigint,
  'AC-STASH-01: a row that was only inserted is put aside too, not left behind');

SELECT grove.stash_pop();

SELECT is(
  (SELECT name FROM st WHERE id = 1), 'work in progress',
  'AC-STASH-01: popping brings the uncommitted work back');

SELECT is(
  (SELECT count(*)::int FROM grove.stash_list()), 0,
  'AC-STASH-01: and takes it off the list');

SELECT is((SELECT count(*) FROM st WHERE id = 9999), 1::bigint,
  'AC-STASH-01: the inserted row comes back as well');
SELECT ok(grove.is_dirty(),
  'AC-STASH-01: and the working tree is uncommitted again, as it was before stashing');
SELECT cmp_ok((SELECT count(*) FROM grove.changes WHERE commit_sha IS NULL), '>', 0::bigint,
  'AC-STASH-01: with the journal holding it once more, so the next commit will record it');
SELECT is((SELECT count(*) FROM grove.fsck()), 0::bigint,
  'AC-STASH-01: and the store is clean throughout');

SELECT throws_ok(
  $$ SELECT grove.stash_pop() $$,
  NULL, NULL,
  'AC-STASH-01: popping an empty stash is refused rather than silently doing nothing');

SELECT * FROM finish();
ROLLBACK;
