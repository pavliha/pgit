BEGIN;
SELECT plan(5);

SELECT isnt(grove.setting('canon_version'), NULL, 'AC-CANON-07: canon_version is recorded');
SELECT isnt(grove.setting('hash_algo'), NULL, 'AC-CANON-07: hash_algo is recorded');
SELECT isnt(grove.setting('chunk_target'), NULL, 'AC-CANON-07: chunk_target is recorded');

CREATE TABLE v (id int PRIMARY KEY, payload text);
INSERT INTO v SELECT g, 'row-' || g FROM generate_series(1, 5000) g;

CREATE TEMP TABLE at64 AS SELECT grove.tree_root('v') AS root;

UPDATE grove.meta SET value = '16' WHERE key = 'chunk_target';

SELECT isnt(
  grove.tree_root('v'), (SELECT root FROM at64),
  'AC-CANON-07: changing chunk_target changes the tree, so it must be versioned'
);

UPDATE grove.meta SET value = '64' WHERE key = 'chunk_target';

SELECT is(
  grove.tree_root('v'), (SELECT root FROM at64),
  'AC-CANON-07: restoring chunk_target restores the tree'
);

SELECT * FROM finish();
ROLLBACK;
