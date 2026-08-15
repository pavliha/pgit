BEGIN;
SELECT plan(7);

CREATE TABLE doc (id int PRIMARY KEY, title text NOT NULL, body text NOT NULL, owner text NOT NULL);
INSERT INTO doc SELECT g, 't' || g, 'b' || g, 'alice' FROM generate_series(1, 400) g;
SELECT pgit.track('doc');

SET pgit.actor = 'alice';
SELECT pgit.commit('first draft', NULL, now() - interval '100 days');
SET pgit.actor = 'bob';
UPDATE doc SET title = 'bob retitled' WHERE id = 7;
SELECT pgit.commit('retitle', NULL, now() - interval '60 days');
SET pgit.actor = 'carol';
UPDATE doc SET body = 'carol rewrote' WHERE id = 7;
SELECT pgit.commit('rewrite body', NULL, now() - interval '30 days');

SELECT is(
  (SELECT b.actor FROM pgit.blame('doc', '7') b WHERE b.col = 'title'), 'bob',
  'AC-BLAME-01: while the history is intact, blame names who changed the column');

SELECT ok(
  (SELECT b.exact FROM pgit.blame('doc', '7') b WHERE b.col = 'title'),
  'AC-BLAME-01: and marks it exact, because a journal entry proves it');

SELECT ok(
  NOT (SELECT b.exact FROM pgit.blame('doc', '7') b WHERE b.col = 'id'),
  'AC-BLAME-01: a column nobody ever changed is not exact - it was merely present at that commit');

SELECT is(
  pgit.prune(now() - interval '45 days'), 2,
  'AC-BLAME-01: a retention policy removes the commits that carry the evidence');

SELECT ok(
  NOT (SELECT b.exact FROM pgit.blame('doc', '7') b WHERE b.col = 'title'),
  'AC-BLAME-01: so blame stops claiming the title attribution is exact');

SELECT is(
  (SELECT b.value FROM pgit.blame('doc', '7') b WHERE b.col = 'title'), '"bob retitled"'::jsonb,
  'AC-BLAME-01: the value it reports is still the value the table holds');

SELECT is(
  (SELECT b.actor FROM pgit.blame('doc', '7') b WHERE b.col = 'body'), 'carol',
  'AC-BLAME-01: and attribution that survived the prune is untouched');

SELECT * FROM finish();
ROLLBACK;
