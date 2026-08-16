BEGIN;
SELECT plan(6);

CREATE TABLE bl (id int PRIMARY KEY, a text NOT NULL, b text NOT NULL, c text NOT NULL);
INSERT INTO bl SELECT g, 'a0', 'b0', 'c0' FROM generate_series(1, 60) g;
SELECT pgit.track('bl');

CREATE TEMP TABLE expected (id int, col text, msg text, PRIMARY KEY (id, col));

SET pgit.actor = 'base-writer';
SELECT pgit.commit('c0');

DO $$
DECLARE
  step  int;
  which text;
  modu  int;
BEGIN
  FOR step IN 1..12 LOOP
    which := (ARRAY['a', 'b', 'c'])[1 + (step % 3)];
    modu  := 2 + (step % 5);

    EXECUTE format('SET pgit.actor = %L', 'writer' || step);
    EXECUTE format('UPDATE bl SET %I = %L WHERE id %% %s = 0', which, which || step, modu);

    INSERT INTO expected (id, col, msg)
    SELECT b.id, which, 'c' || step FROM bl b WHERE b.id % modu = 0
    ON CONFLICT (id, col) DO UPDATE SET msg = EXCLUDED.msg;

    PERFORM pgit.commit('c' || step, NULL, now(), true);
  END LOOP;
END $$;

CREATE TEMP TABLE checked AS
SELECT e.id, e.col, e.msg AS want,
       (SELECT c.message FROM pgit.commits c
        WHERE c.sha = (SELECT bm.commit_sha FROM pgit.blame('bl', e.id::text) bm
                       WHERE bm.col = e.col)) AS got,
       (SELECT bm.exact FROM pgit.blame('bl', e.id::text) bm WHERE bm.col = e.col) AS exact
FROM expected e
WHERE e.id <= 12;

SELECT cmp_ok(
  (SELECT count(*)::int FROM checked), '>', 15,
  'AC-BLAME-03: the oracle compared a meaningful number of row and column pairs');

SELECT is(
  (SELECT count(*)::int FROM checked WHERE got IS NULL), 0,
  'AC-BLAME-03: blame named a commit for every column it was asked about');

SELECT is(
  (SELECT count(*)::int FROM checked WHERE got IS DISTINCT FROM want), 0,
  'AC-BLAME-03: and it was the commit that actually last wrote that column, computed independently');

SELECT is(
  (SELECT count(*)::int FROM checked WHERE NOT exact), 0,
  'AC-BLAME-03: every one is exact, because a journal entry proves each of them');

SELECT cmp_ok(
  (SELECT count(DISTINCT want)::int FROM checked), '>', 3,
  'AC-BLAME-03: spanning several different commits, so the comparison is not one value against itself');

SELECT is(
  (SELECT bm.actor FROM pgit.blame('bl', '60') bm WHERE bm.col = 'id'), 'base-writer',
  'AC-BLAME-03: a column nobody ever updated is credited to the commit that first recorded the row');

SELECT * FROM finish();
ROLLBACK;
