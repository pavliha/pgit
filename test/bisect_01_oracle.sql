BEGIN;
SELECT plan(3);

CREATE TABLE bo (id int PRIMARY KEY, v int NOT NULL);
INSERT INTO bo SELECT g, 0 FROM generate_series(1, 120) g;
SELECT grove.track('bo');

CREATE TEMP TABLE bisect_result (len int, poison int, expected text, got text);

DO $$
DECLARE
  len     int;
  poison  int;
  step    int;
  pick    bytea;
  prev    bytea;
  guard   int;
  want    text;
BEGIN
  FOR len IN 4..9 LOOP
    FOR poison IN 2..len LOOP
      TRUNCATE grove.nodes, grove.trees, grove.commits, grove.commit_parent,
               grove.changes, grove.refs, grove.schemas, grove.reflog, grove.bisect CASCADE;
      DELETE FROM grove.meta WHERE key = 'head';

      UPDATE bo SET v = 0;
      PERFORM grove.commit('c1', NULL, now(), true);

      FOR step IN 2..len LOOP
        UPDATE bo SET v = CASE WHEN step >= poison THEN 999 ELSE step END WHERE id = 1;
        PERFORM grove.commit('c' || step, NULL, now(), true);
      END LOOP;

      SELECT c.message INTO want FROM grove.commits c
      WHERE c.message = 'c' || poison;

      prev  := NULL;
      guard := 0;
      pick  := grove.bisect_start('HEAD~' || (len - 1), 'HEAD');

      WHILE pick IS NOT NULL AND pick IS DISTINCT FROM prev AND guard < 30 LOOP
        prev  := pick;
        guard := guard + 1;
        IF (SELECT v FROM bo WHERE id = 1) = 999 THEN
          pick := grove.bisect_bad();
        ELSE
          pick := grove.bisect_good();
        END IF;
      END LOOP;

      INSERT INTO bisect_result
      SELECT len, poison, want,
             (SELECT c.message FROM grove.commits c JOIN grove.bisect b ON b.bad = c.sha);

      PERFORM grove.bisect_reset();
    END LOOP;
  END LOOP;
END $$;

SELECT is(
  (SELECT count(*)::int FROM bisect_result), 33,
  'AC-BISECT-01: every history length from 4 to 9 was bisected at every poison position');

SELECT is(
  (SELECT count(*)::int FROM bisect_result WHERE got IS DISTINCT FROM expected), 0,
  'AC-BISECT-01: and every one converged on exactly the commit that introduced the bad value');

SELECT is(
  (SELECT count(*)::int FROM bisect_result WHERE got IS NULL OR expected IS NULL), 0,
  'AC-BISECT-01: with a real commit named on both sides of every comparison, not two nulls');

SELECT * FROM finish();
ROLLBACK;
