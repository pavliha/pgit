BEGIN;
SELECT plan(6);

CREATE TABLE t (id int PRIMARY KEY, name text);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'row-'||g FROM generate_series(1,50) g;
SELECT grove.commit('c1 base','alice');

UPDATE t SET name = 'edited' WHERE id <= 10;
CREATE TEMP TABLE c2 AS SELECT grove.commit('c2 edits','alice') AS sha;

SELECT ok(grove.revert((SELECT sha FROM c2)) IS NOT NULL,
  'revert: undoing the newest commit works when nothing moved since');
SELECT is((SELECT name FROM t WHERE id = 1), 'row-1',
  'revert: and the rows really did go back, so the refusals below are not vacuous');

UPDATE t SET name = 'edited again' WHERE id <= 10;
CREATE TEMP TABLE c3 AS SELECT grove.commit('c3 edits again','alice') AS sha;
UPDATE t SET name = 'touched by hand' WHERE id = 3;

SELECT throws_like($$ SELECT grove.revert((SELECT sha FROM c3)) $$, '%refusing to revert%',
  'revert: a row changed by hand since that commit stops it, rather than overwriting the change');
SELECT is((SELECT name FROM t WHERE id = 3), 'touched by hand',
  'revert: and nothing was applied on the way to refusing');

SELECT grove.commit('c4 keeps the hand edit','alice');
ALTER TABLE t ADD COLUMN note text;
UPDATE t SET note = 'note ' || id;
SELECT grove.commit('c5 adds a column','bob');

SELECT throws_like($$ SELECT grove.revert((SELECT sha FROM c3)) $$, '%refusing to revert%',
  'revert: a commit from before a column was added is refused, its rows no longer hash the same');
SELECT is((SELECT count(*) FROM t WHERE note IS NOT NULL), 50::bigint,
  'revert: so the column added afterwards is not silently blanked by replaying old row images');

SELECT * FROM finish();
ROLLBACK;
