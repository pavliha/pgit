BEGIN;
SELECT plan(6);

CREATE TABLE t (id int PRIMARY KEY, name text, hits int);
SELECT grove.track('t');
INSERT INTO t VALUES (1, 'one', 0), (2, 'two', 0), (3, 'three', 0);
CREATE TEMP TABLE base AS SELECT grove.commit('base', 'pavlo') AS sha;

SELECT grove.branch('feature');

UPDATE t SET name = 'picked' WHERE id = 2;
CREATE TEMP TABLE pick AS SELECT grove.commit('the commit to pick', 'pavlo') AS sha;

SELECT grove.checkout('feature');
CREATE TEMP TABLE before_pick AS SELECT grove.tree_root('t') AS root;

SELECT is(grove.cherry_pick((SELECT sha FROM pick)), 0, 'cherry-pick applies cleanly');

SELECT is((SELECT name FROM t WHERE id = 2), 'picked', 'cherry-pick brought the change across');

SELECT isnt(
  grove.resolve('feature'), (SELECT sha FROM pick),
  'cherry-pick creates a new commit rather than reusing the original sha'
);

SELECT grove.revert(grove.resolve('feature'));

SELECT is(
  grove.tree_root('t'), (SELECT root FROM before_pick),
  'AC-REPLAY-06: cherry-pick followed by revert is a content no-op'
);

UPDATE t SET name = 'feature version' WHERE id = 2;
SELECT grove.commit('feature edits the same row', 'pavlo');

SELECT is(
  grove.cherry_pick((SELECT sha FROM pick)), 1,
  'cherry-pick of a commit that touches the same cell reports a conflict'
);

SELECT is(
  (SELECT name FROM t WHERE id = 2), 'feature version',
  'a conflicted cherry-pick applies nothing to the working tree'
);

SELECT * FROM finish();
ROLLBACK;
