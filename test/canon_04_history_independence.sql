BEGIN;
SELECT plan(6);

CREATE TABLE base (id int PRIMARY KEY, name text, amount numeric);
INSERT INTO base
SELECT g, 'row-' || g, (g * 7 % 1000)::numeric / 100
FROM generate_series(1, 1000) g;

CREATE TEMP TABLE expected AS SELECT pgit.tree_root('base') AS root;

CREATE TABLE shuffled (LIKE base INCLUDING ALL);
INSERT INTO shuffled SELECT * FROM base ORDER BY random();

SELECT is(
  pgit.tree_root('shuffled'), (SELECT root FROM expected),
  'AC-CANON-04: insertion order does not change the root hash'
);

CREATE TABLE shuffled2 (LIKE base INCLUDING ALL);
INSERT INTO shuffled2 SELECT * FROM base ORDER BY md5(id::text);

SELECT is(
  pgit.tree_root('shuffled2'), (SELECT root FROM expected),
  'AC-CANON-04: a second, different insertion order agrees too'
);

CREATE TABLE updated (LIKE base INCLUDING ALL);
INSERT INTO updated SELECT id, 'wrong', 0 FROM base;
UPDATE updated u SET name = b.name, amount = b.amount FROM base b WHERE b.id = u.id;

SELECT is(
  pgit.tree_root('updated'), (SELECT root FROM expected),
  'AC-CANON-04: reaching a value by UPDATE equals inserting it directly'
);

CREATE TABLE deleted (LIKE base INCLUDING ALL);
INSERT INTO deleted SELECT * FROM base;
INSERT INTO deleted
SELECT g, 'row-' || g, (g * 7 % 1000)::numeric / 100
FROM generate_series(1001, 2000) g;
DELETE FROM deleted WHERE id > 1000;

SELECT is(
  pgit.tree_root('deleted'), (SELECT root FROM expected),
  'AC-CANON-04: insert-then-delete equals never having inserted'
);

CREATE TABLE churned (LIKE base INCLUDING ALL);
INSERT INTO churned SELECT * FROM base;
UPDATE churned SET amount = amount + 1;
UPDATE churned SET amount = amount - 1;
DELETE FROM churned WHERE id % 3 = 0;
INSERT INTO churned SELECT * FROM base WHERE id % 3 = 0;

SELECT is(
  pgit.tree_root('churned'), (SELECT root FROM expected),
  'AC-CANON-04: 3000 operations returning to the same content return to the same hash'
);

CREATE TABLE empty_a (id int PRIMARY KEY, name text, amount numeric);
CREATE TABLE empty_b (id int PRIMARY KEY, name text, amount numeric);
INSERT INTO empty_b SELECT * FROM base;
DELETE FROM empty_b;

SELECT is(
  pgit.tree_root('empty_a'), pgit.tree_root('empty_b'),
  'AC-CANON-04: an emptied table hashes as an empty one'
);

SELECT * FROM finish();
ROLLBACK;
