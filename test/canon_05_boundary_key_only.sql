BEGIN;
SELECT plan(3);

CREATE TABLE k1 (id int PRIMARY KEY, payload text);
INSERT INTO k1 SELECT g, 'a' FROM generate_series(1, 2000) g;

CREATE TABLE k2 (LIKE k1 INCLUDING ALL);
INSERT INTO k2 SELECT * FROM k1 ORDER BY random();

CREATE TABLE k3 (LIKE k1 INCLUDING ALL);
INSERT INTO k3 SELECT id, 'completely different payload' FROM k1;

CREATE TEMP TABLE b1 AS
  SELECT key_bytes FROM grove.row_hashes('k1') WHERE grove.is_boundary(key_bytes);
CREATE TEMP TABLE b2 AS
  SELECT key_bytes FROM grove.row_hashes('k2') WHERE grove.is_boundary(key_bytes);
CREATE TEMP TABLE b3 AS
  SELECT key_bytes FROM grove.row_hashes('k3') WHERE grove.is_boundary(key_bytes);

SELECT ok(
  NOT EXISTS (SELECT key_bytes FROM b1 EXCEPT SELECT key_bytes FROM b2)
  AND NOT EXISTS (SELECT key_bytes FROM b2 EXCEPT SELECT key_bytes FROM b1),
  'AC-CANON-05: the boundary key set is identical under a different insertion order'
);

SELECT ok(
  NOT EXISTS (SELECT key_bytes FROM b1 EXCEPT SELECT key_bytes FROM b3)
  AND NOT EXISTS (SELECT key_bytes FROM b3 EXCEPT SELECT key_bytes FROM b1),
  'AC-CANON-05: boundaries depend on the key alone, not on row payload'
);

SELECT ok(
  (SELECT count(*) FROM b1) > 0,
  'AC-CANON-05: 2000 keys produce at least one boundary'
);

SELECT * FROM finish();
ROLLBACK;
