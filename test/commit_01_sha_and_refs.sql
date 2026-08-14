BEGIN;
SELECT plan(12);

CREATE TABLE t (id int PRIMARY KEY, name text);
SELECT pgit.track('t');
INSERT INTO t VALUES (1, 'first'), (2, 'second');

CREATE TEMP TABLE c1 AS SELECT pgit.commit('initial', 'pavlo') AS sha;

SELECT isnt((SELECT sha FROM c1), NULL, 'commit: returns a sha');

SELECT is(
  (SELECT parent_sha FROM pgit.commits WHERE sha = (SELECT sha FROM c1)),
  NULL, 'commit: the first commit has no parent'
);

SELECT is(
  pgit.resolve('main'), (SELECT sha FROM c1),
  'commit: the branch ref points at the new commit'
);

SELECT is(
  (SELECT count(*) FROM pgit.trees WHERE commit_sha = (SELECT sha FROM c1)),
  1::bigint, 'commit: one tree root recorded per tracked table'
);

UPDATE t SET name = 'changed' WHERE id = 1;
CREATE TEMP TABLE c2 AS SELECT pgit.commit('second', 'pavlo') AS sha;

SELECT is(
  (SELECT parent_sha FROM pgit.commits WHERE sha = (SELECT sha FROM c2)),
  (SELECT sha FROM c1), 'commit: the second commit parents the first'
);

SELECT isnt(
  (SELECT root_hash FROM pgit.trees WHERE commit_sha = (SELECT sha FROM c2)),
  (SELECT root_hash FROM pgit.trees WHERE commit_sha = (SELECT sha FROM c1)),
  'commit: changing a row changes the recorded tree root'
);

SELECT is(
  pgit.commit_sha(NULL, 'a', 'm', '2026-01-01 00:00:00+00', 'tree'),
  pgit.commit_sha(NULL, 'a', 'm', '2026-01-01 00:00:00+00', 'tree'),
  'AC-COMMIT-05: the sha is a pure function of its inputs'
);

SELECT isnt(
  pgit.commit_sha(NULL, 'a', 'm', '2026-01-01 00:00:00+00', 'tree'),
  pgit.commit_sha('\xaa'::bytea, 'a', 'm', '2026-01-01 00:00:00+00', 'tree'),
  'AC-COMMIT-06: identical content under a different parent gets a different sha'
);

SELECT isnt(
  pgit.commit_sha(NULL, 'a', 'm', '2026-01-01 00:00:00+00', 'tree'),
  pgit.commit_sha(NULL, 'a', 'm2', '2026-01-01 00:00:00+00', 'tree'),
  'AC-COMMIT-05: the message is part of the sha'
);

SELECT isnt(
  pgit.commit_sha(NULL, 'a', 'm', '2026-01-01 00:00:00+00', 'tree'),
  pgit.commit_sha(NULL, 'a', 'm', '2026-01-01 00:00:01+00', 'tree'),
  'AC-COMMIT-05: the timestamp is part of the sha'
);

SELECT throws_ok(
  format($$ SELECT pgit.advance_ref('main', %L::bytea, %L::bytea) $$,
         (SELECT sha FROM c1), (SELECT sha FROM c1)),
  NULL, NULL,
  'AC-REF-01: advancing a ref from a stale expected sha is refused'
);

SELECT lives_ok(
  format($$ SELECT pgit.advance_ref('main', %L::bytea, %L::bytea) $$,
         (SELECT sha FROM c2), (SELECT sha FROM c1)),
  'AC-REF-01: advancing a ref from the correct expected sha succeeds'
);

SELECT * FROM finish();
ROLLBACK;
