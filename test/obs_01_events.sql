BEGIN;
SELECT plan(11);

CREATE TABLE ev (id int PRIMARY KEY, v text NOT NULL);
INSERT INTO ev SELECT g, 'v' || g FROM generate_series(1, 300) g;
SELECT pgit.track('ev');
SELECT pgit.commit('base');

SELECT is(
  (SELECT count(*)::int FROM pgit.events WHERE verb = 'commit'), 1,
  'AC-OBS-01: a commit records exactly one wide event, not a scatter of log lines');

SELECT is(
  (SELECT e.actor FROM pgit.events e WHERE e.verb = 'commit'), current_user::text,
  'AC-OBS-01: the event carries who did it');

SELECT is(
  (SELECT e.branch FROM pgit.events e WHERE e.verb = 'commit'), 'main',
  'AC-OBS-01: and which branch it happened on');

SELECT is(
  (SELECT e.detail ->> 'sha' FROM pgit.events e WHERE e.verb = 'commit'),
  pgit.short_sha(pgit.resolve('main')),
  'AC-OBS-01: with the high cardinality field that ties it to the commit');

SELECT cmp_ok(
  (SELECT e.duration_ms FROM pgit.events e WHERE e.verb = 'commit'), '>', 0::numeric,
  'AC-OBS-01: and how long it took, so latency is measurable without a stopwatch');

UPDATE ev SET v = 'x' WHERE id < 20;
SELECT pgit.commit('second');

SELECT is(
  (SELECT (e.detail ->> 'journal_rows')::int FROM pgit.events e
   WHERE e.verb = 'commit' ORDER BY e.id DESC LIMIT 1), 19,
  'AC-OBS-01: the event counts the work done, not just that it happened');

SELECT pgit.branch('l');
SELECT pgit.branch('r');
SELECT pgit.checkout('l');
UPDATE ev SET v = 'left' WHERE id = 1;
SELECT pgit.commit('left');
SELECT pgit.checkout('r');
UPDATE ev SET v = 'right' WHERE id = 1;
SELECT pgit.commit('right');
SELECT pgit.merge('l', 'conflicting merge');

SELECT is(
  (SELECT e.ok FROM pgit.events e WHERE e.verb = 'merge' ORDER BY e.id DESC LIMIT 1), false,
  'AC-OBS-01: a merge that stopped on conflicts is recorded as not ok');

SELECT is(
  (SELECT (e.detail ->> 'conflicts')::int FROM pgit.events e
   WHERE e.verb = 'merge' ORDER BY e.id DESC LIMIT 1), 1,
  'AC-OBS-01: with the conflict count in the same event');

SELECT is(
  (SELECT value FROM pgit.metrics() WHERE metric = 'pgit_events_failed'), 1::numeric,
  'AC-OBS-02: metrics counts failed operations for a scraper');

SELECT cmp_ok(
  (SELECT value FROM pgit.metrics() WHERE metric = 'pgit_commit_ms_p50'), '>', 0::numeric,
  'AC-OBS-02: and reports commit latency percentiles from the recorded events');

UPDATE pgit.meta SET value = 'off' WHERE key = 'log_events';
UPDATE ev SET v = 'quiet' WHERE id = 2;
SELECT pgit.commit('while logging is off');

SELECT is(
  (SELECT count(*)::int FROM pgit.events WHERE detail ->> 'sha' = pgit.short_sha(pgit.resolve(pgit.head()))), 0,
  'AC-OBS-03: turning logging off really stops it, so it can be switched off under load');

SELECT * FROM finish();
ROLLBACK;
