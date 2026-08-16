BEGIN;
SELECT plan(9);

CREATE TABLE t (id int PRIMARY KEY, name text, hits int);
SELECT grove.track('t');
INSERT INTO t VALUES (1,'alpha',10),(2,'keep',20),(3,'other',30);
CREATE TEMP TABLE b AS SELECT grove.commit('base','p') AS sha;
SELECT grove.branch('feature');

UPDATE t SET name='beta' WHERE id=1;
CREATE TEMP TABLE mn AS SELECT grove.commit('main edits the name','p') AS sha;

SELECT grove.checkout('feature');
UPDATE t SET id=100 WHERE id=1;
CREATE TEMP TABLE ft AS SELECT grove.commit('feature changes the key','p') AS sha;

SELECT is(
  (SELECT count(*) FROM grove.rename_pairs(
     (SELECT root_hash FROM grove.trees WHERE commit_sha=(SELECT sha FROM b) AND tbl='t'),
     (SELECT root_hash FROM grove.trees WHERE commit_sha=(SELECT sha FROM ft) AND tbl='t'),
     ARRAY['id'])), 1::bigint,
  'renames: a primary key change is detected as one rename, not a delete plus an insert');

SELECT is(
  (SELECT round(sim,2) FROM grove.rename_pairs(
     (SELECT root_hash FROM grove.trees WHERE commit_sha=(SELECT sha FROM b) AND tbl='t'),
     (SELECT root_hash FROM grove.trees WHERE commit_sha=(SELECT sha FROM ft) AND tbl='t'),
     ARRAY['id'])), 1.00,
  'renames: an otherwise untouched row scores a perfect similarity');

SELECT is(grove.merge('main'), 0,
  'renames: the merge completes instead of raising a delete versus modify conflict');

SELECT is((SELECT name FROM t WHERE id=100), 'beta',
  'renames: the other branch edit was carried onto the renamed row');

SELECT is((SELECT hits FROM t WHERE id=100), 10,
  'renames: the untouched columns survived the rename');

SELECT is((SELECT count(*) FROM t WHERE id=1), 0::bigint,
  'renames: the old key is gone');

SELECT grove.branch('side');
UPDATE t SET name='feature edited row two' WHERE id=2;
SELECT grove.commit('feature edits row two','p');

SELECT grove.checkout('side');
DELETE FROM t WHERE id=2;
INSERT INTO t VALUES (200,'utterly different content',777);
SELECT grove.commit('side replaces row two','p');

SELECT is(grove.merge('feature'), 1,
  'renames: a dissimilar delete and insert is not mistaken for a rename');

SELECT is(
  (SELECT count(*) FROM grove.conflicts WHERE NOT resolved), 1::bigint,
  'renames: that case still surfaces as a real conflict to resolve');

SELECT is(
  (SELECT count(*) FROM grove.rename_pairs(
     (SELECT root_hash FROM grove.trees WHERE commit_sha=(SELECT sha FROM b) AND tbl='t'),
     (SELECT root_hash FROM grove.trees WHERE commit_sha=(SELECT sha FROM ft) AND tbl='t'),
     ARRAY['id'], 1.01)), 0::bigint,
  'renames: raising the threshold above one finds nothing, so the threshold is honoured');

SELECT * FROM finish();
ROLLBACK;
