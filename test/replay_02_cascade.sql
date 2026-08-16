BEGIN;
SELECT plan(5);

CREATE TABLE parents (id int PRIMARY KEY, label text);
CREATE TABLE children (
  id        int PRIMARY KEY,
  parent_id int NOT NULL REFERENCES parents(id) ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE,
  note      text
);

SELECT grove.track('parents');
SELECT grove.track('children');

INSERT INTO parents SELECT g, 'parent-' || g FROM generate_series(1, 20) g;
INSERT INTO children SELECT g, 1 + (g % 20), 'child-' || g FROM generate_series(1, 100) g;

CREATE TEMP TABLE a AS SELECT grove.commit('a', 'pavlo') AS sha;

DELETE FROM parents WHERE id = 3;

SELECT is(
  (SELECT count(*) FROM children WHERE parent_id = 3), 0::bigint,
  'the cascade removed the children'
);

CREATE TEMP TABLE b AS SELECT grove.commit('b', 'pavlo') AS sha;

SELECT ok(
  (SELECT count(*) FROM grove.diff((SELECT sha FROM a), (SELECT sha FROM b), 'children')) > 0,
  'the cascaded child deletes were journalled and appear in the diff'
);

SELECT grove.revert((SELECT sha FROM b));

SELECT is(
  (SELECT count(*) FROM parents WHERE id = 3), 1::bigint,
  'AC-REPLAY-05: revert restores the cascaded parent'
);

SELECT is(
  grove.tree_root('children'),
  (SELECT root_hash FROM grove.trees WHERE commit_sha = (SELECT sha FROM a) AND tbl = 'children'),
  'AC-REPLAY-05: revert restores every cascaded child, by root hash'
);

SET CONSTRAINTS ALL IMMEDIATE;

SELECT is(
  (SELECT count(*) FROM children c LEFT JOIN parents p ON p.id = c.parent_id WHERE p.id IS NULL),
  0::bigint,
  'AC-REPLAY-05: the restored state satisfies every foreign key'
);

SELECT * FROM finish();
ROLLBACK;
