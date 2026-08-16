BEGIN;
SELECT plan(10);

CREATE TABLE t (id int PRIMARY KEY, name text, amount numeric);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'row-' || g, g FROM generate_series(1, 300) g;

CREATE TEMP TABLE a AS SELECT grove.commit('a', 'pavlo') AS sha;
CREATE TABLE snapshot_a (LIKE t INCLUDING ALL);
INSERT INTO snapshot_a SELECT * FROM t;

SELECT is(
  (SELECT count(*) FROM grove.diff((SELECT sha FROM a), (SELECT sha FROM a))),
  0::bigint, 'AC-DIFF-01: diff of a commit against itself is empty'
);

UPDATE t SET name = 'changed' WHERE id = 100;
DELETE FROM t WHERE id = 200;
INSERT INTO t VALUES (999, 'new row', 42);

CREATE TEMP TABLE b AS SELECT grove.commit('b', 'pavlo') AS sha;

SELECT is(
  (SELECT count(*) FROM grove.diff((SELECT sha FROM a), (SELECT sha FROM b))),
  3::bigint, 'diff: reports exactly the three changed rows'
);

SELECT is(
  (SELECT op FROM grove.diff((SELECT sha FROM a), (SELECT sha FROM b)) WHERE after ->> 'id' = '999'),
  'INSERT', 'diff: a new row is an INSERT'
);

SELECT is(
  (SELECT op FROM grove.diff((SELECT sha FROM a), (SELECT sha FROM b)) WHERE before ->> 'id' = '200'),
  'DELETE', 'diff: a removed row is a DELETE'
);

SELECT is(
  (SELECT before ->> 'name' || '->' || (after ->> 'name')
   FROM grove.diff((SELECT sha FROM a), (SELECT sha FROM b)) WHERE before ->> 'id' = '100'),
  'row-100->changed', 'diff: an updated row carries both images'
);

SELECT is(
  (SELECT count(*) FROM grove.diff((SELECT sha FROM b), (SELECT sha FROM a))),
  3::bigint, 'AC-DIFF-03: the reverse diff reports the same three rows'
);

SELECT is(
  (SELECT op FROM grove.diff((SELECT sha FROM b), (SELECT sha FROM a)) WHERE before ->> 'id' = '999'),
  'DELETE', 'AC-DIFF-03: the reverse diff inverts INSERT into DELETE'
);

SELECT is(
  grove.apply_diff('snapshot_a', (SELECT sha FROM a), (SELECT sha FROM b), 't'),
  3, 'AC-DIFF-02: applying the diff touches three rows'
);

SELECT is(
  grove.tree_root('snapshot_a'),
  (SELECT root_hash FROM grove.trees WHERE commit_sha = (SELECT sha FROM b) AND tbl = 't'),
  'AC-DIFF-02: apply(diff(A,B), A) produces B, checked by root hash'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM grove.diff((SELECT sha FROM a), (SELECT sha FROM b))
    WHERE COALESCE(before ->> 'id', after ->> 'id') NOT IN ('100', '200', '999')
  ),
  'diff: no unchanged row is ever reported'
);

SELECT * FROM finish();
ROLLBACK;
