BEGIN;
SELECT plan(4);

CREATE TABLE seq_keys (id bigint PRIMARY KEY, v text);
INSERT INTO seq_keys SELECT g, 'x' FROM generate_series(1, 20000) g;

CREATE TABLE uuid4_keys (id uuid PRIMARY KEY, v text);
INSERT INTO uuid4_keys SELECT gen_random_uuid(), 'x' FROM generate_series(1, 20000) g;

CREATE TABLE uuid7_keys (id uuid PRIMARY KEY, v text);
INSERT INTO uuid7_keys SELECT uuidv7(), 'x' FROM generate_series(1, 20000) g;

CREATE TABLE prefix_keys (id text PRIMARY KEY, v text);
INSERT INTO prefix_keys
SELECT 'INTO-PRODUCT-SKU-000000000' || g, 'x' FROM generate_series(1, 20000) g;

CREATE TEMP TABLE dist AS
SELECT 'sequential' AS shape, rows, chunks FROM pgit.chunk_stats('seq_keys')
UNION ALL SELECT 'uuidv4', rows, chunks FROM pgit.chunk_stats('uuid4_keys')
UNION ALL SELECT 'uuidv7', rows, chunks FROM pgit.chunk_stats('uuid7_keys')
UNION ALL SELECT 'common-prefix', rows, chunks FROM pgit.chunk_stats('prefix_keys');

SELECT ok(
  (SELECT rows::numeric / chunks BETWEEN 16 AND 256 FROM dist WHERE shape = 'sequential'),
  'AC-CANON-06: sequential integer keys chunk within 4x of the 64 target'
);

SELECT ok(
  (SELECT rows::numeric / chunks BETWEEN 16 AND 256 FROM dist WHERE shape = 'uuidv4'),
  'AC-CANON-06: uuidv4 keys chunk within 4x of the 64 target'
);

SELECT ok(
  (SELECT rows::numeric / chunks BETWEEN 16 AND 256 FROM dist WHERE shape = 'uuidv7'),
  'AC-CANON-06: uuidv7 keys chunk within 4x of the 64 target'
);

SELECT ok(
  (SELECT rows::numeric / chunks BETWEEN 16 AND 256 FROM dist WHERE shape = 'common-prefix'),
  'AC-CANON-06: keys sharing a 25-character prefix chunk within 4x of the 64 target'
);

SELECT * FROM finish();
ROLLBACK;
