BEGIN;
SELECT plan(4);

CREATE TABLE cats (id int PRIMARY KEY, name text);
CREATE TABLE prods (
  id     int PRIMARY KEY,
  cat_id int NOT NULL REFERENCES cats(id) DEFERRABLE INITIALLY IMMEDIATE,
  name   text
);
SELECT grove.track('cats');
SELECT grove.track('prods');

INSERT INTO cats VALUES (1, 'one'), (2, 'two'), (3, 'doomed');
CREATE TEMP TABLE base AS SELECT grove.commit('base', 'pavlo') AS sha;

SELECT grove.branch('feature');

DELETE FROM cats WHERE id = 3;
SELECT grove.commit('main drops the category', 'pavlo');

SELECT grove.checkout('feature');
INSERT INTO prods VALUES (1, 3, 'needs the doomed category');
CREATE TEMP TABLE feature_head AS SELECT grove.commit('feature adds a product', 'pavlo') AS sha;

SELECT is(
  (SELECT count(*) FROM grove.merge_plan(
     (SELECT sha FROM base), grove.resolve('feature'), grove.resolve('main'))
   WHERE action = 'conflict'),
  0::bigint,
  'AC-MERGE-08: no per-cell conflict exists, the two branches touched different tables'
);

SELECT throws_ok(
  $$ SELECT grove.merge('main') $$,
  NULL, NULL,
  'AC-MERGE-08: the merge aborts on the foreign key rather than dangling the reference'
);

SELECT is(
  (SELECT count(*) FROM cats WHERE id = 3), 1::bigint,
  'AC-MERGE-10: the doomed category is still present after the aborted merge'
);

SELECT is(
  grove.resolve('feature'), (SELECT sha FROM feature_head),
  'AC-MERGE-10: the aborted merge did not move the branch ref'
);

SELECT * FROM finish();
ROLLBACK;
