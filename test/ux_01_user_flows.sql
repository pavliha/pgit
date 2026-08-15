BEGIN;
SELECT plan(12);

CREATE TABLE ux (id int PRIMARY KEY, name text NOT NULL, price numeric(10,2) NOT NULL);
INSERT INTO ux VALUES (1, 'Filament PLA', 25.00), (2, 'Nozzle', 8.00);

SELECT pgit.track('ux');
SELECT pgit.commit('initial catalogue', NULL, now());

SELECT isnt(
  (SELECT author FROM pgit.log() ORDER BY depth LIMIT 1), NULL,
  'AC-UX-01: a commit records an author without the user configuring one first');

SELECT is(
  (SELECT count(*)::int FROM pgit.blame('ux', '1')), 3,
  'AC-UX-02: blame attributes every column of a row that existed before track()');

SELECT is(
  (SELECT b.commit_sha FROM pgit.blame('ux', '1') b WHERE b.col = 'name'),
  pgit.resolve('main'),
  'AC-UX-02: and credits them to the commit that first recorded the row');

SELECT throws_ok(
  $$ SELECT pgit.commit('nothing changed at all') $$,
  NULL,
  NULL,
  'AC-UX-03: committing an unchanged working tree is refused, not silently recorded');

SELECT is(
  (SELECT count(*)::int FROM pgit.commits), 1,
  'AC-UX-03: so a repeating job cannot fill history with empty commits');

SELECT isnt(
  pgit.commit('deliberate marker', NULL, now(), true), NULL,
  'AC-UX-03: unless the caller asks for an empty commit on purpose');

UPDATE ux SET price = 27.50 WHERE id = 1;
SELECT pgit.commit('raise the price');

SELECT is(
  (SELECT b.value FROM pgit.blame('ux', '1') b WHERE b.col = 'price'), '27.50'::jsonb,
  'AC-UX-02: blame follows a later change to a single column');

SELECT is(
  (SELECT b.commit_sha FROM pgit.blame('ux', '1') b WHERE b.col = 'price'),
  pgit.resolve('main'),
  'AC-UX-02: and moves that column to the newer commit while the rest stay put');

CREATE TEMP TABLE reverted AS SELECT pgit.revert(pgit.resolve('main')) AS sha;

SELECT is(
  (SELECT sha FROM reverted), pgit.resolve('main'),
  'AC-UX-04: revert records a commit and returns it, the way cherry_pick does');

SELECT is(
  (SELECT price FROM ux WHERE id = 1), 25.00,
  'AC-UX-04: the reverted value is back in the table');

SELECT ok(
  NOT pgit.is_dirty(),
  'AC-UX-04: and revert leaves nothing uncommitted to leak into the next commit');

SELECT is(
  (SELECT message FROM pgit.log() ORDER BY depth LIMIT 1), 'Revert "raise the price"',
  'AC-UX-04: with a message naming what it reverted');

SELECT * FROM finish();
ROLLBACK;
