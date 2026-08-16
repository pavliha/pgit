BEGIN;
SELECT plan(5);

CREATE TABLE t (id int PRIMARY KEY, name text, hits int);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'row-' || g, 0 FROM generate_series(1, 300) g;

CREATE TEMP TABLE chain (n serial, sha bytea);
INSERT INTO chain (sha) SELECT grove.commit('base', 'fuzz');

DO $$
DECLARE
  i int; j int; r int; k int;
BEGIN
  PERFORM setseed(0.42);
  FOR i IN 1..50 LOOP
    FOR j IN 1..20 LOOP
      r := (random() * 2.999)::int;
      k := 1 + (random() * 299)::int;
      IF r = 0 THEN
        INSERT INTO t VALUES (k, 'v' || (random() * 1000)::int, (random() * 100)::int)
        ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, hits = EXCLUDED.hits;
      ELSIF r = 1 THEN
        UPDATE t SET hits = (random() * 100)::int WHERE id = k;
      ELSE
        DELETE FROM t WHERE id = k;
      END IF;
    END LOOP;
    INSERT INTO chain (sha) SELECT grove.commit('round ' || i, 'fuzz');
  END LOOP;
END $$;

SELECT is(
  (SELECT count(*) FROM chain), 51::bigint,
  'AC-DIFF-04: 1000 random operations produced 51 commits'
);

CREATE TEMP TABLE pairs AS
SELECT a.sha AS a, b.sha AS b
FROM chain a JOIN chain b ON b.n > a.n
ORDER BY random()
LIMIT 40;

CREATE TEMP TABLE compared AS
SELECT p.a, p.b,
  (SELECT count(*) FROM grove.diff(p.a, p.b))         AS tree_rows,
  (SELECT count(*) FROM grove.diff_journal(p.a, p.b)) AS journal_rows,
  (SELECT count(*) FROM (
     (SELECT d.tbl, d.op, d.before, d.after FROM grove.diff(p.a, p.b) d
      EXCEPT ALL
      SELECT j.tbl, j.op, j.before, j.after FROM grove.diff_journal(p.a, p.b) j)
     UNION ALL
     (SELECT j.tbl, j.op, j.before, j.after FROM grove.diff_journal(p.a, p.b) j
      EXCEPT ALL
      SELECT d.tbl, d.op, d.before, d.after FROM grove.diff(p.a, p.b) d)
   ) q) AS mismatches
FROM pairs p;

SELECT ok(
  (SELECT sum(tree_rows) FROM compared) > 100,
  'AC-DIFF-04: the sampled pairs contain real differences, so the test is not vacuous'
);

SELECT is(
  (SELECT sum(mismatches) FROM compared), 0::numeric,
  'AC-DIFF-04: tree descent and journal replay agree on every one of 40 commit pairs'
);

SELECT is(
  (SELECT count(*) FROM compared WHERE tree_rows <> journal_rows), 0::bigint,
  'AC-DIFF-04: both implementations report the same number of changed rows'
);

CREATE TABLE snapshot (LIKE t INCLUDING ALL);
INSERT INTO snapshot SELECT id, name, 0 FROM t WHERE false;

SELECT is(
  (SELECT count(*) FROM compared WHERE tree_rows = 0), 0::bigint,
  'AC-DIFF-04: no sampled pair collapsed to an empty diff, which would hide disagreement'
);

SELECT * FROM finish();
ROLLBACK;
