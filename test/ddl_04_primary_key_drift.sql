BEGIN;
SELECT plan(7);

CREATE TABLE t (a int PRIMARY KEY, b int, note text);
SELECT grove.track('t');
INSERT INTO t VALUES (1,10,'first'), (2,20,'second');
SELECT grove.commit('base','alice');

SELECT is((SELECT count(*) FROM grove.fsck()), 0::bigint,
  'key drift: a freshly tracked table is clean');

ALTER TABLE t DROP CONSTRAINT t_pkey;
ALTER TABLE t ADD PRIMARY KEY (b);

SELECT is(grove.schema_fingerprint('t'),
  (SELECT fingerprint FROM grove.schemas WHERE tbl = 't' LIMIT 1),
  'key drift: the shape fingerprint is unchanged, it covers columns and not the key');

SELECT is((SELECT count(*) FROM grove.fsck()
           WHERE problem = 'primary key changed since the table was tracked'), 1::bigint,
  'key drift: fsck names the changed primary key directly');

INSERT INTO t VALUES (1, 30, 'same a, different b');

SELECT throws_like($$ SELECT grove.commit('after the key changed','bob') $$,
  '%primary key of t changed since it was tracked%',
  'key drift: committing is refused rather than writing a tree the journal disagrees with');

SELECT grove.track('t');

SELECT ok(grove.commit('re-tracked','bob') IS NOT NULL,
  'key drift: re-tracking adopts the new key and lets the commit through');

SELECT is((SELECT count(*) FROM grove.fsck()), 0::bigint,
  'key drift: clean again after re-tracking');

SELECT is((SELECT count(*) FROM grove.leaves(
             (SELECT root_hash FROM grove.trees
              WHERE commit_sha = grove.resolve('main') AND tbl = 't'))), 3::bigint,
  'key drift: all three rows are in the tree, keyed by the new primary key');

SELECT * FROM finish();
ROLLBACK;
