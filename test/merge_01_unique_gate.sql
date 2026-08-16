BEGIN;
SELECT plan(5);

CREATE TABLE users (id int PRIMARY KEY, email text UNIQUE);
SELECT grove.track('users');
INSERT INTO users VALUES (1, 'a@example.com');
CREATE TEMP TABLE base AS SELECT grove.commit('base', 'pavlo') AS sha;

SELECT grove.branch('feature');

INSERT INTO users VALUES (2, 'contested@example.com');
SELECT grove.commit('main adds user 2', 'pavlo');

SELECT grove.checkout('feature');
INSERT INTO users VALUES (3, 'contested@example.com');
CREATE TEMP TABLE feature_head AS SELECT grove.commit('feature adds user 3', 'pavlo') AS sha;

SELECT is(
  (SELECT count(*) FROM grove.merge_plan(
     (SELECT sha FROM base), grove.resolve('feature'), grove.resolve('main'))
   WHERE action = 'conflict'),
  0::bigint,
  'AC-MERGE-07: the two branches have no per-cell conflict, so a naive merge would happily proceed'
);

SELECT is(
  (SELECT count(*) FROM grove.merge_plan(
     (SELECT sha FROM base), grove.resolve('feature'), grove.resolve('main'))),
  1::bigint,
  'AC-MERGE-07: the plan is a single clean upsert of the other branch new row'
);

SELECT throws_ok(
  $$ SELECT grove.merge('main') $$,
  NULL, NULL,
  'AC-MERGE-07: the merge aborts on the unique index, caught by Postgres rather than by grove'
);

SELECT is(
  (SELECT count(*) FROM users), 2::bigint,
  'AC-MERGE-10: the aborted merge left the working tree exactly as it was'
);

SELECT is(
  grove.resolve('feature'), (SELECT sha FROM feature_head),
  'AC-MERGE-10: the aborted merge did not move the branch ref'
);

SELECT * FROM finish();
ROLLBACK;
