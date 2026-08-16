BEGIN;
SELECT plan(5);

CREATE TABLE ca (id int PRIMARY KEY, v text NOT NULL);
INSERT INTO ca SELECT g, 'v' || g FROM generate_series(1, 300) g;
SELECT grove.track('ca');
SELECT grove.commit('base');

SET grove.actor = 'alice';
UPDATE ca SET v = 'alice wrote this' WHERE id BETWEEN 1 AND 10;

SELECT is(
  (SELECT count(*)::int FROM grove.changes WHERE commit_sha IS NULL), 10,
  'AC-OBS-06: a write that has not been committed sits pending in the journal');

SET grove.actor = 'bob';
UPDATE ca SET v = 'bob wrote this' WHERE id BETWEEN 100 AND 102;
SELECT grove.commit('bob commits');

SELECT is(
  (SELECT count(*)::int FROM grove.changes ch WHERE ch.commit_sha = grove.resolve('main')), 13,
  'AC-OBS-06: committing claims every pending row, including another actors uncommitted work');

SELECT is(
  (SELECT c.author FROM grove.commits c WHERE c.sha = grove.resolve('main')), 'bob',
  'AC-OBS-06: so the commit author is whoever ran commit, not whoever made the change');

SELECT is(
  (SELECT b.actor FROM grove.blame('ca', '5') b WHERE b.col = 'v'), 'alice',
  'AC-OBS-06: but blame still credits the row to the actor who wrote it');

SELECT ok(
  (SELECT b.exact FROM grove.blame('ca', '5') b WHERE b.col = 'v'),
  'AC-OBS-06: and marks that attribution exact, because the journal captured it at write time');

SELECT * FROM finish();
ROLLBACK;
