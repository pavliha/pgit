BEGIN;
SELECT plan(5);

CREATE TABLE users (id int PRIMARY KEY, email text UNIQUE);
SELECT pgit.track('users');
INSERT INTO users VALUES (1, 'a@example.com');
CREATE TEMP TABLE base AS SELECT pgit.commit('base', 'pavlo') AS sha;

SELECT pgit.branch('feature');

INSERT INTO users VALUES (2, 'contested@example.com');
SELECT pgit.commit('main adds user 2', 'pavlo');

SELECT pgit.checkout('feature');
INSERT INTO users VALUES (3, 'contested@example.com');
CREATE TEMP TABLE feature_head AS SELECT pgit.commit('feature adds user 3', 'pavlo') AS sha;

SELECT is(
  (SELECT count(*) FROM pgit.merge_plan(
     (SELECT sha FROM base), pgit.resolve('feature'), pgit.resolve('main'))
   WHERE action = 'conflict'),
  0::bigint,
  'AC-MERGE-07: the two branches have no per-cell conflict, so a naive merge would happily proceed'
);

SELECT is(
  (SELECT count(*) FROM pgit.merge_plan(
     (SELECT sha FROM base), pgit.resolve('feature'), pgit.resolve('main'))),
  1::bigint,
  'AC-MERGE-07: the plan is a single clean upsert of the other branch new row'
);

SELECT throws_ok(
  $$ SELECT pgit.merge('main') $$,
  NULL, NULL,
  'AC-MERGE-07: the merge aborts on the unique index, caught by Postgres rather than by pgit'
);

SELECT is(
  (SELECT count(*) FROM users), 2::bigint,
  'AC-MERGE-10: the aborted merge left the working tree exactly as it was'
);

SELECT is(
  pgit.resolve('feature'), (SELECT sha FROM feature_head),
  'AC-MERGE-10: the aborted merge did not move the branch ref'
);

SELECT * FROM finish();
ROLLBACK;
