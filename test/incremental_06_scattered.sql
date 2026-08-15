BEGIN;
SELECT plan(7);

CREATE TABLE r (k text PRIMARY KEY, n int);
SELECT pgit.track('r');
INSERT INTO r SELECT 'tt' || lpad(g::text, 8, '0'), g FROM generate_series(1, 200000) g;
ANALYZE r;
SELECT pgit.commit('base', 'p');

CREATE TEMP TABLE t_ms (what text PRIMARY KEY, ms numeric);

DO $$
DECLARE t0 timestamptz;
BEGIN
  t0 := clock_timestamp();
  PERFORM pgit.write_tree('r');
  INSERT INTO t_ms VALUES ('rebuild', extract(epoch FROM clock_timestamp() - t0) * 1000);

  UPDATE r SET n = n + 1 WHERE k BETWEEN 'tt00050000' AND 'tt00050999';
  t0 := clock_timestamp();
  PERFORM pgit.commit('1000 adjacent', 'p');
  INSERT INTO t_ms VALUES ('adjacent', extract(epoch FROM clock_timestamp() - t0) * 1000);

  UPDATE r SET n = n + 1 WHERE ('x' || md5(k))::bit(32)::int % 200 = 0;
  t0 := clock_timestamp();
  PERFORM pgit.commit('1000 scattered', 'p');
  INSERT INTO t_ms VALUES ('scattered', extract(epoch FROM clock_timestamp() - t0) * 1000);
END $$;

SELECT cmp_ok((SELECT count(*) FROM pgit.diff(pgit.rev('main~1'), pgit.resolve('main')))::int,
  '>', 500, 'scattered: the scattered commit really did change ~1000 rows');

SELECT is(
  pgit.write_tree('r'),
  (SELECT root_hash FROM pgit.trees WHERE commit_sha = pgit.resolve('main') AND tbl = 'r'),
  'scattered: the spliced tree still equals a full rebuild');

SELECT is(pgit.is_dirty(), false, 'scattered: the working tree is clean');

SELECT cmp_ok(
  (SELECT ms FROM t_ms WHERE what = 'scattered'), '<',
  (SELECT ms * 3 / 2 FROM t_ms WHERE what = 'rebuild'),
  'scattered: a scattered commit costs less than one and a half full rebuilds');

SELECT cmp_ok(
  (SELECT ms FROM t_ms WHERE what = 'adjacent'), '<',
  (SELECT ms / 2 FROM t_ms WHERE what = 'rebuild'),
  'scattered: an adjacent commit of the same size stays well under a rebuild');

SELECT cmp_ok(
  (SELECT ms FROM t_ms WHERE what = 'adjacent'), '<',
  (SELECT ms FROM t_ms WHERE what = 'scattered'),
  'scattered: adjacent is still the cheaper shape, so splicing is doing its job');

SELECT cmp_ok((SELECT ms FROM t_ms WHERE what = 'rebuild'), '>', 200::numeric,
  'scattered: the rebuild reference is large enough to compare against meaningfully');

SELECT * FROM finish();
ROLLBACK;
