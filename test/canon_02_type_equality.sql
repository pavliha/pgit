BEGIN;
SELECT plan(10);

CREATE TABLE num_a (id int PRIMARY KEY, v numeric);
CREATE TABLE num_b (id int PRIMARY KEY, v numeric);
INSERT INTO num_a VALUES (1, 1.0), (2, 250), (3, 0.5);
INSERT INTO num_b VALUES (1, 1.0000), (2, 250.00), (3, 0.50);

SELECT is(
  pgit.tree_root('num_a'), pgit.tree_root('num_b'),
  'AC-CANON-02: numeric 1.0 = 1.0000 hashes identically'
);

CREATE TABLE flt_a (id int PRIMARY KEY, v float8);
CREATE TABLE flt_b (id int PRIMARY KEY, v float8);
INSERT INTO flt_a VALUES (1, 0.0), (2, 'NaN'), (3, 1.5);
INSERT INTO flt_b VALUES (1, -0.0), (2, 'NaN'), (3, 1.5);

SELECT is(
  pgit.tree_root('flt_a'), pgit.tree_root('flt_b'),
  'AC-CANON-02: float 0.0 = -0.0 and NaN = NaN hash identically'
);

CREATE TABLE nan_a (id int PRIMARY KEY, v numeric);
CREATE TABLE nan_b (id int PRIMARY KEY, v numeric);
INSERT INTO nan_a VALUES (1, 'NaN');
INSERT INTO nan_b VALUES (1, 'NaN');

SELECT is(
  pgit.tree_root('nan_a'), pgit.tree_root('nan_b'),
  'AC-CANON-02: numeric NaN is stable'
);

CREATE TABLE ts_a (id int PRIMARY KEY, v timestamptz);
CREATE TABLE ts_b (id int PRIMARY KEY, v timestamptz);
INSERT INTO ts_a VALUES (1, '2026-01-01 00:00:00+00');
INSERT INTO ts_b VALUES (1, '2026-01-01 03:00:00+03');

SELECT is(
  pgit.tree_root('ts_a'), pgit.tree_root('ts_b'),
  'AC-CANON-02: the same instant written in two offsets hashes identically'
);

CREATE TEMP TABLE tz_snap AS SELECT pgit.tree_root('ts_a') AS root;
SET LOCAL TimeZone = 'Pacific/Kiritimati';

SELECT is(
  pgit.tree_root('ts_a'), (SELECT root FROM tz_snap),
  'AC-CANON-02: session TimeZone does not change the hash'
);

SET LOCAL TimeZone = 'UTC';

CREATE TABLE uni_a (id int PRIMARY KEY, v text);
CREATE TABLE uni_b (id int PRIMARY KEY, v text);
INSERT INTO uni_a VALUES (1, U&'caf\00E9');
INSERT INTO uni_b VALUES (1, U&'cafe\0301');

SELECT is(
  pgit.tree_root('uni_a'), pgit.tree_root('uni_b'),
  'AC-CANON-02: NFC and NFD forms of the same string hash identically'
);

CREATE TYPE order_state AS ENUM ('pending', 'paid', 'shipped');
CREATE TABLE enum_a (id int PRIMARY KEY, v order_state);
CREATE TABLE enum_b (id int PRIMARY KEY, v text);
INSERT INTO enum_a VALUES (1, 'paid');
INSERT INTO enum_b VALUES (1, 'paid');

SELECT is(
  pgit.tree_root('enum_a'), pgit.tree_root('enum_b'),
  'AC-CANON-02: enums hash by label, not by oid or ordinal'
);

CREATE DOMAIN price AS numeric;
CREATE TABLE dom_a (id int PRIMARY KEY, v price);
CREATE TABLE dom_b (id int PRIMARY KEY, v numeric);
INSERT INTO dom_a VALUES (1, 9.90);
INSERT INTO dom_b VALUES (1, 9.9);

SELECT is(
  pgit.tree_root('dom_a'), pgit.tree_root('dom_b'),
  'AC-CANON-02: a domain normalises as its base type'
);

SELECT is(
  (SELECT count(*) FROM (VALUES ('abc'), (''), ('ქართული'), (E'e\u0301'), (E'\u00e9'),
                                ('日本語'), ('mixed ascii and ქართული'), (NULL)) v(x)
   WHERE pgit.canon_text(x) IS DISTINCT FROM normalize(x, NFC)),
  0::bigint,
  'AC-CANON-02: the ascii fast path agrees with normalize on every form, NFD and NULL included'
);

SELECT isnt(
  (SELECT pgit.canon_text(E'e\u0301')), E'e\u0301',
  'AC-CANON-02: and it really does normalise a decomposed string, so the check is not vacuous'
);

SELECT * FROM finish();
ROLLBACK;
