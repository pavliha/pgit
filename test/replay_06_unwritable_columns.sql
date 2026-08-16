BEGIN;
SELECT plan(10);

CREATE TABLE g (
  id     int PRIMARY KEY,
  price  numeric NOT NULL,
  qty    int     NOT NULL,
  total  numeric GENERATED ALWAYS AS (price * qty) STORED
);
SELECT grove.track('g');
INSERT INTO g (id, price, qty) VALUES (1, 10, 2), (2, 5, 3);
CREATE TEMP TABLE g0 AS SELECT grove.commit('generated base', 'p') AS sha;

SELECT is((SELECT total FROM g WHERE id = 1), 20::numeric,
  'generated: the column really is populated, so the fixture is not vacuous');

UPDATE g SET qty = 10 WHERE id = 1;
SELECT grove.commit('bump qty', 'p');
SELECT is((SELECT total FROM g WHERE id = 1), 100::numeric, 'generated: it recomputed on update');

SELECT grove.reset(encode((SELECT sha FROM g0), 'hex'), 'hard');

SELECT is((SELECT qty FROM g WHERE id = 1), 2, 'generated: reset --hard restored the source column');
SELECT is((SELECT total FROM g WHERE id = 1), 20::numeric,
  'generated: and the generated column followed it back');
SELECT is(grove.is_dirty(), false, 'generated: the tree is clean after replaying over a generated column');

DELETE FROM g WHERE id = 2;
SELECT grove.commit('drop one', 'p');
SELECT grove.reset(encode((SELECT sha FROM g0), 'hex'), 'hard');
SELECT is((SELECT count(*) FROM g), 2::bigint, 'generated: a reinserted row comes back too');
SELECT is((SELECT total FROM g WHERE id = 2), 15::numeric,
  'generated: the reinserted row recomputed its generated column');

CREATE TABLE ident (
  id   int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  note text
);
SELECT grove.track('ident');
INSERT INTO ident (note) VALUES ('first'), ('second');
CREATE TEMP TABLE i0 AS SELECT grove.commit('identity base', 'p') AS sha;

DELETE FROM ident;
SELECT grove.commit('cleared', 'p');
SELECT is((SELECT count(*) FROM ident), 0::bigint, 'identity: the rows really were removed');

SELECT grove.reset(encode((SELECT sha FROM i0), 'hex'), 'hard');
SELECT is((SELECT string_agg(note, ',' ORDER BY id) FROM ident), 'first,second',
  'identity: restoring rows into a GENERATED ALWAYS AS IDENTITY key works');
SELECT is(grove.is_dirty(), false, 'identity: and the restored table matches the commit exactly');

SELECT * FROM finish();
ROLLBACK;
