BEGIN;
SELECT plan(8);

CREATE TABLE seq_keys (id bigint PRIMARY KEY, v text);
INSERT INTO seq_keys SELECT g, 'x' FROM generate_series(1, 20000) g;

CREATE TABLE uuid4_keys (id uuid PRIMARY KEY, v text);
INSERT INTO uuid4_keys SELECT gen_random_uuid(), 'x' FROM generate_series(1, 20000) g;

CREATE TABLE uuid7_keys (id uuid PRIMARY KEY, v text);
INSERT INTO uuid7_keys
SELECT (lpad(to_hex((extract(epoch from clock_timestamp()) * 1000)::bigint), 12, '0')
        || '7' || substr(md5(random()::text), 1, 3)
        || 'a' || substr(md5(random()::text), 1, 15))::uuid, 'x'
FROM generate_series(1, 20000) g;

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

CREATE TABLE spin ("Id Col" int PRIMARY KEY, v text);
SELECT pgit.track('spin');
INSERT INTO spin VALUES (1, 'a'), (2, 'b');

SELECT ok(
  pgit.is_boundary(convert_to('Id Col=#1:1|', 'UTF8'), pgit.setting('chunk_target')::int),
  'AC-CANON-06: the fixture really is the pathological shape, first key on a boundary');

CREATE TEMP TABLE spin_c AS SELECT pgit.commit('spin base', 'main') AS sha;

SELECT is(
  pgit.write_tree('spin'),
  (SELECT root_hash FROM pgit.trees WHERE commit_sha = (SELECT sha FROM spin_c) AND tbl = 'spin'),
  'AC-CANON-06: a level that cannot shrink still builds, and matches a rebuild');

UPDATE spin SET v = 'z' WHERE "Id Col" = 1;
SELECT pgit.commit('spin update', 'main');

SELECT is(
  pgit.write_tree('spin'),
  (SELECT root_hash FROM pgit.trees WHERE commit_sha = pgit.resolve('main') AND tbl = 'spin'),
  'AC-CANON-06: and the incremental path agrees with a full rebuild on it');

INSERT INTO spin VALUES (3, 'c');
DELETE FROM spin WHERE "Id Col" = 2;
SELECT pgit.commit('spin churn', 'main');

SELECT is(
  pgit.write_tree('spin'),
  (SELECT root_hash FROM pgit.trees WHERE commit_sha = pgit.resolve('main') AND tbl = 'spin'),
  'AC-CANON-06: through an insert and a delete as well');

SELECT * FROM finish();
ROLLBACK;
