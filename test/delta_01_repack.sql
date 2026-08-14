BEGIN;
SELECT plan(10);

CREATE TABLE t (id int PRIMARY KEY, name text, body text, hits int);
SELECT pgit.track('t');
INSERT INTO t SELECT g, 'row-' || g, repeat('payload ', 20) || g, 0 FROM generate_series(1, 5000) g;
CREATE TEMP TABLE a AS SELECT pgit.commit('base', 'b') AS sha;

DO $$ DECLARE i int; BEGIN
  FOR i IN 1..150 LOOP
    UPDATE t SET hits = i WHERE id = 2000 + i;
    PERFORM pgit.commit('c' || i, 'b');
  END LOOP;
END $$;

CREATE TEMP TABLE before_entries AS SELECT hash, pgit.entries_of(hash) AS e FROM pgit.nodes;
CREATE TEMP TABLE before_trees   AS SELECT commit_sha, tbl, root_hash FROM pgit.trees;
CREATE TEMP TABLE before_diff    AS SELECT * FROM pgit.diff((SELECT sha FROM a), pgit.resolve('main'));
CREATE TEMP TABLE before_blame   AS SELECT * FROM pgit.blame('t', '2100');
CREATE TEMP TABLE before_size    AS
  SELECT sum(pg_column_size(entries) + COALESCE(pg_column_size(delta), 0))::bigint AS sz,
         count(*) AS n FROM pgit.nodes;

CREATE TEMP TABLE packed AS SELECT pgit.repack() AS n;

SELECT cmp_ok((SELECT n FROM packed), '>', 100,
  'repack: more than a hundred node versions were deltified');

SELECT is(
  (SELECT count(*) FROM pgit.nodes WHERE entries IS NULL), (SELECT n FROM packed)::bigint,
  'repack: exactly the deltified nodes now store a delta instead of full entries'
);

SELECT is(
  (SELECT count(*) FROM before_entries b
   WHERE b.e IS DISTINCT FROM pgit.entries_of(b.hash)), 0::bigint,
  'repack: every node resolves to byte identical entries afterwards'
);

SELECT is(
  (SELECT count(*) FROM pgit.trees t
   JOIN before_trees b ON b.commit_sha = t.commit_sha AND b.tbl = t.tbl
   WHERE b.root_hash IS DISTINCT FROM t.root_hash), 0::bigint,
  'repack: no tree root changed, so content addressing is preserved'
);

SELECT is(
  (SELECT count(*) FROM (
     SELECT * FROM pgit.diff((SELECT sha FROM a), pgit.resolve('main'))
     EXCEPT ALL SELECT * FROM before_diff) q), 0::bigint,
  'repack: diff returns exactly the same rows'
);

SELECT is(
  (SELECT count(*) FROM (
     SELECT * FROM pgit.blame('t', '2100') EXCEPT ALL SELECT * FROM before_blame) q), 0::bigint,
  'repack: blame returns exactly the same rows'
);

SELECT is(
  pgit.write_tree('t'),
  (SELECT root_hash FROM pgit.trees WHERE commit_sha = pgit.resolve('main') AND tbl = 't'),
  'repack: a fresh full rebuild still matches the packed tree'
);

SELECT cmp_ok(
  (SELECT sum(pg_column_size(entries) + COALESCE(pg_column_size(delta), 0))::bigint FROM pgit.nodes),
  '<', (SELECT sz * 3 / 4 FROM before_size),
  'repack: the default depth cuts stored bytes by at least a quarter'
);

CREATE TEMP TABLE unpacked AS SELECT pgit.unpack() AS n;

SELECT is((SELECT n FROM unpacked), (SELECT n FROM packed),
  'unpack: every deltified node was materialised again');

SELECT is(
  (SELECT count(*) FROM before_entries b
   WHERE b.e IS DISTINCT FROM pgit.entries_of(b.hash)), 0::bigint,
  'unpack: entries are identical again after a full round trip'
);

SELECT * FROM finish();
ROLLBACK;
