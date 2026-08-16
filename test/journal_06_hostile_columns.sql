BEGIN;
SELECT plan(7);

CREATE TABLE hostile (
  id      int PRIMARY KEY,
  n text, o text, cols text, t text, s text, v text, k text, e text,
  i text, j text, r text, g text, b text, a text, x text, y text,
  c text, d text, h text, hs text, ks text, es text,
  img text, target text, tbl text, key text, hash text, image text,
  entries text, keys text, hashes text, grove_t text, grove_s text,
  newrows text, oldrows text, node text, chunk text, depth text
);
SELECT grove.track('hostile');

INSERT INTO hostile (id, n, o, t, s, hash, image, keys, target)
VALUES (1, 'n1', 'o1', 't1', 's1', 'h1', 'i1', 'k1', 'g1'),
       (2, 'n2', 'o2', 't2', 's2', 'h2', 'i2', 'k2', 'g2'),
       (3, 'n3', 'o3', 't3', 's3', 'h3', 'i3', 'k3', 'g3');

SELECT is(
  (SELECT jsonb_typeof(after) FROM grove.changes
   WHERE tbl = 'hostile' AND after ->> 'id' = '1'),
  'object',
  'hostile: the journal records a row object for a table named after every alias');

CREATE TEMP TABLE h_base AS SELECT grove.commit('hostile base', 'main') AS sha;

SELECT is(
  jsonb_typeof((SELECT grove.entries_of(root_hash) -> 0 FROM grove.trees
                WHERE tbl = 'hostile' AND commit_sha = (SELECT sha FROM h_base))),
  'object',
  'hostile: and the tree stores row objects, not a scalar from a shadowed alias');

SELECT is(
  (SELECT grove.entries_of(root_hash) -> 0 ->> 't' FROM grove.trees
   WHERE tbl = 'hostile' AND commit_sha = (SELECT sha FROM h_base)),
  't1',
  'hostile: every column keeps its own value');

SELECT is(
  grove.write_tree('hostile'),
  (SELECT root_hash FROM grove.trees WHERE tbl = 'hostile' AND commit_sha = (SELECT sha FROM h_base)),
  'hostile: the recorded tree matches a full rebuild');

SELECT grove.branch('hostileside', (SELECT sha FROM h_base));
SELECT grove.checkout('hostileside');
UPDATE hostile SET t = 'changed', hash = 'changed' WHERE id = 2;
DELETE FROM hostile WHERE id = 3;
INSERT INTO hostile (id, t) VALUES (4, 'added');
SELECT grove.commit('hostile side', 'hostileside');
SELECT grove.checkout('main');

SELECT is(
  (SELECT t FROM hostile WHERE id = 2), 't2',
  'hostile: checkout restores an update across all of them');

SELECT is(
  (SELECT count(*) FROM hostile)::int, 3,
  'hostile: and the delete and the insert are undone too');

SELECT is(
  grove.write_tree('hostile'),
  (SELECT root_hash FROM grove.trees WHERE tbl = 'hostile' AND commit_sha = grove.resolve('main')),
  'hostile: the tree still matches a rebuild after replaying back');

SELECT * FROM finish();
ROLLBACK;
