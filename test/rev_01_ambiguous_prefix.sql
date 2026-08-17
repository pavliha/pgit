BEGIN;
SELECT plan(9);

CREATE TABLE t (id int PRIMARY KEY, a text);
SELECT grove.track('t');
INSERT INTO t VALUES (1, 'v0');
SELECT grove.commit('c0', 'pavlo', '2020-01-01'::timestamptz);

DO $$
DECLARE i int;
BEGIN
  FOR i IN 1..600 LOOP
    UPDATE t SET a = 'v' || i;
    PERFORM grove.commit('c' || i, 'pavlo',
                         '2020-01-01'::timestamptz + (i || ' minutes')::interval);
  END LOOP;
END $$;

CREATE TEMP TABLE shared AS
  SELECT left(encode(sha, 'hex'), 4) AS pfx, count(*) AS n
  FROM grove.commits GROUP BY 1 HAVING count(*) > 1 ORDER BY 1;

SELECT cmp_ok((SELECT count(*) FROM shared), '>', 0::bigint,
  'AC-REV: the fixture really produced a four character prefix shared by two commits, so this is not vacuous');

SELECT set_config('probe.pfx', (SELECT pfx FROM shared LIMIT 1), false);

SELECT cmp_ok((SELECT count(*) FROM grove.commits
               WHERE encode(sha, 'hex') LIKE current_setting('probe.pfx') || '%'), '>', 1::bigint,
  'AC-REV: and that prefix does match more than one commit');

SELECT set_config('probe.head', encode(grove.resolve('main'), 'hex'), false);

SELECT throws_like(
  $$ SELECT grove.rev(current_setting('probe.pfx')) $$,
  '%is ambiguous%',
  'AC-REV: rev refuses an ambiguous prefix, where it used to return whichever row came first');

SELECT throws_like(
  $$ SELECT grove.rev(current_setting('probe.pfx')) $$,
  '%matches 2 commits%',
  'AC-REV: and says how many it matched');

SELECT throws_like(
  $$ SELECT grove.reset(current_setting('probe.pfx'), 'hard') $$,
  '%is ambiguous%',
  'AC-REV: so a hard reset aimed at it refuses instead of discarding history at an arbitrary target');

SELECT is(encode(grove.resolve('main'), 'hex'), current_setting('probe.head'),
  'AC-REV: and the branch did not move');

SELECT is(
  (SELECT c.message FROM grove.commits c WHERE c.sha = grove.rev(
     (SELECT encode(sha, 'hex') FROM grove.commits WHERE message = 'c7'))),
  'c7',
  'AC-REV: a full sha still resolves');

SELECT is(
  (SELECT c.message FROM grove.commits c WHERE c.sha = grove.rev(
     (SELECT left(encode(sha, 'hex'), 16) FROM grove.commits WHERE message = 'c7'))),
  'c7',
  'AC-REV: and so does a longer prefix that is still unique');

SELECT throws_like(
  $$ SELECT grove.rev('deadbeefdeadbeef') $$,
  '%no commit matching%',
  'AC-REV: a prefix matching nothing is still a different error from an ambiguous one');

SELECT * FROM finish();
ROLLBACK;
