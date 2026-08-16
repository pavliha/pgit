BEGIN;
SELECT plan(13);

CREATE TABLE t (id int PRIMARY KEY, name text, hits int);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'row-' || g, 0 FROM generate_series(1, 200) g;
CREATE TEMP TABLE c1 AS SELECT grove.commit('base', 'pavlo') AS sha;

SELECT grove.branch('feature');

SELECT is(grove.resolve('feature'), (SELECT sha FROM c1), 'branch: the new ref starts at HEAD');

SELECT is(
  (SELECT string_agg(name || CASE WHEN is_head THEN '*' ELSE '' END, ',' ORDER BY name)
   FROM grove.branches()),
  'feature,main*', 'branch: branches lists both refs and marks the checked out one'
);

SELECT throws_ok(
  $$ SELECT grove.branch('feature') $$, NULL, NULL,
  'branch: creating a branch that already exists is refused'
);

UPDATE t SET name = 'uncommitted edit' WHERE id = 1;

SELECT throws_ok(
  $$ SELECT grove.checkout('feature') $$, NULL, NULL,
  'AC-REF-02: checkout with uncommitted changes is refused'
);

UPDATE t SET name = 'row-1' WHERE id = 1;

SELECT is(
  grove.is_dirty(), false,
  'branch: dirtiness is decided by content, so restoring the old value makes the tree clean again'
);

SELECT is(grove.checkout('feature'), 0, 'AC-REF-03: checking out an identical commit writes no rows');
SELECT is(grove.head(), 'feature', 'branch: checkout moves HEAD');

UPDATE t SET name = 'feature work' WHERE id BETWEEN 10 AND 12;
CREATE TEMP TABLE c2 AS SELECT grove.commit('feature work', 'pavlo') AS sha;

SELECT is(
  grove.checkout('main'), 3,
  'AC-REF-03: checkout writes only the differing rows, not the whole 200 row table'
);

SELECT is(
  grove.tree_root('t'),
  (SELECT root_hash FROM grove.trees WHERE commit_sha = (SELECT sha FROM c1) AND tbl = 't'),
  'branch: checking out main restores its content exactly'
);

SELECT is(
  grove.checkout('feature'), 3,
  'AC-REF-03: switching back writes only the differing rows again'
);

SELECT is(
  grove.tree_root('t'),
  (SELECT root_hash FROM grove.trees WHERE commit_sha = (SELECT sha FROM c2) AND tbl = 't'),
  'branch: checking out feature restores its content exactly'
);

SELECT throws_ok(
  $$ SELECT grove.delete_branch('feature') $$, NULL, NULL,
  'branch: deleting the checked out branch is refused'
);

SELECT grove.branch('scratch', (SELECT sha FROM c1));
SELECT grove.delete_branch('scratch');

SELECT is(
  grove.tree_root('t'),
  (SELECT root_hash FROM grove.trees WHERE commit_sha = (SELECT sha FROM c2) AND tbl = 't'),
  'AC-REF-04: deleting a branch leaves every other ref and its tree intact'
);

SELECT * FROM finish();
ROLLBACK;
