BEGIN;
SELECT plan(3);

CREATE TABLE t (id int PRIMARY KEY, name text, hits int);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'row-' || g, 0 FROM generate_series(1, 20000) g;
SELECT grove.commit('base', 'fuzz');

SELECT cmp_ok(
  grove.node_level((SELECT root_hash FROM grove.trees
                   WHERE commit_sha = grove.resolve('main') AND tbl = 't')),
  '>=', 2,
  'incremental: 20000 rows build a tree at least three levels deep, so the level 1 splice is exercised'
);

CREATE TEMP TABLE mismatch (round int);

DO $$
DECLARE
  i int; j int; r int; k int;
  prev bytea; inc bytea; fullr bytea;
BEGIN
  PERFORM setseed(0.31);
  prev := (SELECT root_hash FROM grove.trees
           WHERE commit_sha = grove.resolve('main') AND tbl = 't');

  FOR i IN 1..15 LOOP
    FOR j IN 1..8 LOOP
      r := (random() * 2.999)::int;
      k := 1 + (random() * 19999)::int;
      IF r = 0 THEN
        INSERT INTO t VALUES (k, 'v' || (random() * 1000)::int, (random() * 50)::int)
        ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;
      ELSIF r = 1 THEN
        UPDATE t SET hits = (random() * 50)::int WHERE id = k;
      ELSE
        DELETE FROM t WHERE id = k;
      END IF;
    END LOOP;

    inc   := grove.write_tree_incremental('t', prev);
    fullr := grove.write_tree('t');
    IF inc IS DISTINCT FROM fullr THEN
      INSERT INTO mismatch VALUES (i);
    END IF;

    PERFORM grove.commit('round ' || i, 'fuzz');
    prev := fullr;
  END LOOP;
END $$;

SELECT is(
  (SELECT count(*) FROM mismatch), 0::bigint,
  'incremental: on a three level tree the incremental root matches the full rebuild every round'
);

DELETE FROM t WHERE id BETWEEN 8000 AND 11000;
CREATE TEMP TABLE prev2 AS
  SELECT root_hash AS root FROM grove.trees
  WHERE commit_sha = grove.resolve('main') AND tbl = 't';

SELECT is(
  grove.write_tree_incremental('t', (SELECT root FROM prev2)),
  grove.write_tree('t'),
  'incremental: deleting 3000 consecutive rows spanning many level 1 nodes still matches'
);

SELECT * FROM finish();
ROLLBACK;
