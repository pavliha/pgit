BEGIN;
SELECT plan(12);

CREATE TABLE t (id int PRIMARY KEY, name text);
SELECT grove.track('t');
INSERT INTO t VALUES (1, 'first'), (2, 'second');

CREATE TEMP TABLE c1 AS SELECT grove.commit('initial', 'pavlo') AS sha;

SELECT isnt((SELECT sha FROM c1), NULL, 'commit: returns a sha');

SELECT is(
  (SELECT parent_sha FROM grove.commits WHERE sha = (SELECT sha FROM c1)),
  NULL, 'commit: the first commit has no parent'
);

SELECT is(
  grove.resolve('main'), (SELECT sha FROM c1),
  'commit: the branch ref points at the new commit'
);

SELECT is(
  (SELECT count(*) FROM grove.trees WHERE commit_sha = (SELECT sha FROM c1)),
  1::bigint, 'commit: one tree root recorded per tracked table'
);

UPDATE t SET name = 'changed' WHERE id = 1;
CREATE TEMP TABLE c2 AS SELECT grove.commit('second', 'pavlo') AS sha;

SELECT is(
  (SELECT parent_sha FROM grove.commits WHERE sha = (SELECT sha FROM c2)),
  (SELECT sha FROM c1), 'commit: the second commit parents the first'
);

SELECT isnt(
  (SELECT root_hash FROM grove.trees WHERE commit_sha = (SELECT sha FROM c2)),
  (SELECT root_hash FROM grove.trees WHERE commit_sha = (SELECT sha FROM c1)),
  'commit: changing a row changes the recorded tree root'
);

SELECT is(
  grove.commit_sha(NULL, 'a', 'm', '2026-01-01 00:00:00+00', 'tree'),
  grove.commit_sha(NULL, 'a', 'm', '2026-01-01 00:00:00+00', 'tree'),
  'AC-COMMIT-05: the sha is a pure function of its inputs'
);

SELECT isnt(
  grove.commit_sha(NULL, 'a', 'm', '2026-01-01 00:00:00+00', 'tree'),
  grove.commit_sha('\xaa'::bytea, 'a', 'm', '2026-01-01 00:00:00+00', 'tree'),
  'AC-COMMIT-06: identical content under a different parent gets a different sha'
);

SELECT isnt(
  grove.commit_sha(NULL, 'a', 'm', '2026-01-01 00:00:00+00', 'tree'),
  grove.commit_sha(NULL, 'a', 'm2', '2026-01-01 00:00:00+00', 'tree'),
  'AC-COMMIT-05: the message is part of the sha'
);

SELECT isnt(
  grove.commit_sha(NULL, 'a', 'm', '2026-01-01 00:00:00+00', 'tree'),
  grove.commit_sha(NULL, 'a', 'm', '2026-01-01 00:00:01+00', 'tree'),
  'AC-COMMIT-05: the timestamp is part of the sha'
);

SELECT throws_ok(
  format($$ SELECT grove.advance_ref('main', %L::bytea, %L::bytea) $$,
         (SELECT sha FROM c1), (SELECT sha FROM c1)),
  NULL, NULL,
  'AC-REF-01: advancing a ref from a stale expected sha is refused'
);

SELECT lives_ok(
  format($$ SELECT grove.advance_ref('main', %L::bytea, %L::bytea) $$,
         (SELECT sha FROM c2), (SELECT sha FROM c1)),
  'AC-REF-01: advancing a ref from the correct expected sha succeeds'
);

SELECT * FROM finish();
ROLLBACK;
