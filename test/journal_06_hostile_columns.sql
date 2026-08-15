BEGIN;
SELECT plan(7);

-- Every identifier the generated SQL has ever used as an alias, all at once, as
-- column names on one tracked table. This collision has been found three times
-- in this project - n and o in the journal trigger, t and s in the row hash and
-- replay SQL, t again in changed_keys - and each fix only covered the names that
-- had bitten so far. A bare alias anywhere in generated SQL fails here.
CREATE TABLE hostile (
  id      int PRIMARY KEY,
  n text, o text, cols text, t text, s text, v text, k text, e text,
  i text, j text, r text, g text, b text, a text, x text, y text,
  c text, d text, h text, hs text, ks text, es text,
  img text, target text, tbl text, key text, hash text, image text,
  entries text, keys text, hashes text, pgit_t text, pgit_s text,
  newrows text, oldrows text, node text, chunk text, depth text
);
SELECT pgit.track('hostile');

INSERT INTO hostile (id, n, o, t, s, hash, image, keys, target)
VALUES (1, 'n1', 'o1', 't1', 's1', 'h1', 'i1', 'k1', 'g1'),
       (2, 'n2', 'o2', 't2', 's2', 'h2', 'i2', 'k2', 'g2'),
       (3, 'n3', 'o3', 't3', 's3', 'h3', 'i3', 'k3', 'g3');

SELECT is(
  (SELECT jsonb_typeof(after) FROM pgit.changes
   WHERE tbl = 'hostile' AND after ->> 'id' = '1'),
  'object',
  'hostile: the journal records a row object for a table named after every alias');

CREATE TEMP TABLE h_base AS SELECT pgit.commit('hostile base', 'main') AS sha;

SELECT is(
  jsonb_typeof((SELECT pgit.entries_of(root_hash) -> 0 FROM pgit.trees
                WHERE tbl = 'hostile' AND commit_sha = (SELECT sha FROM h_base))),
  'object',
  'hostile: and the tree stores row objects, not a scalar from a shadowed alias');

SELECT is(
  (SELECT pgit.entries_of(root_hash) -> 0 ->> 't' FROM pgit.trees
   WHERE tbl = 'hostile' AND commit_sha = (SELECT sha FROM h_base)),
  't1',
  'hostile: every column keeps its own value');

SELECT is(
  pgit.write_tree('hostile'),
  (SELECT root_hash FROM pgit.trees WHERE tbl = 'hostile' AND commit_sha = (SELECT sha FROM h_base)),
  'hostile: the recorded tree matches a full rebuild');

SELECT pgit.branch('hostileside', (SELECT sha FROM h_base));
SELECT pgit.checkout('hostileside');
UPDATE hostile SET t = 'changed', hash = 'changed' WHERE id = 2;
DELETE FROM hostile WHERE id = 3;
INSERT INTO hostile (id, t) VALUES (4, 'added');
SELECT pgit.commit('hostile side', 'hostileside');
SELECT pgit.checkout('main');

SELECT is(
  (SELECT t FROM hostile WHERE id = 2), 't2',
  'hostile: checkout restores an update across all of them');

SELECT is(
  (SELECT count(*) FROM hostile)::int, 3,
  'hostile: and the delete and the insert are undone too');

SELECT is(
  pgit.write_tree('hostile'),
  (SELECT root_hash FROM pgit.trees WHERE tbl = 'hostile' AND commit_sha = pgit.resolve('main')),
  'hostile: the tree still matches a rebuild after replaying back');

SELECT * FROM finish();
ROLLBACK;
