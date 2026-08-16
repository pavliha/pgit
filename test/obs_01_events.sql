BEGIN;
SELECT plan(11);

CREATE TABLE ev (id int PRIMARY KEY, v text NOT NULL);
INSERT INTO ev SELECT g, 'v' || g FROM generate_series(1, 300) g;
SELECT grove.track('ev');
SELECT grove.commit('base');

SELECT is(
  (SELECT count(*)::int FROM grove.events WHERE verb = 'commit'), 1,
  'AC-OBS-01: a commit records exactly one wide event, not a scatter of log lines');

SELECT is(
  (SELECT e.actor FROM grove.events e WHERE e.verb = 'commit'), current_user::text,
  'AC-OBS-01: the event carries who did it');

SELECT is(
  (SELECT e.branch FROM grove.events e WHERE e.verb = 'commit'), 'main',
  'AC-OBS-01: and which branch it happened on');

SELECT is(
  (SELECT e.detail ->> 'sha' FROM grove.events e WHERE e.verb = 'commit'),
  grove.short_sha(grove.resolve('main')),
  'AC-OBS-01: with the high cardinality field that ties it to the commit');

SELECT cmp_ok(
  (SELECT e.duration_ms FROM grove.events e WHERE e.verb = 'commit'), '>', 0::numeric,
  'AC-OBS-01: and how long it took, so latency is measurable without a stopwatch');

UPDATE ev SET v = 'x' WHERE id < 20;
SELECT grove.commit('second');

SELECT is(
  (SELECT (e.detail ->> 'journal_rows')::int FROM grove.events e
   WHERE e.verb = 'commit' ORDER BY e.id DESC LIMIT 1), 19,
  'AC-OBS-01: the event counts the work done, not just that it happened');

SELECT grove.branch('l');
SELECT grove.branch('r');
SELECT grove.checkout('l');
UPDATE ev SET v = 'left' WHERE id = 1;
SELECT grove.commit('left');
SELECT grove.checkout('r');
UPDATE ev SET v = 'right' WHERE id = 1;
SELECT grove.commit('right');
SELECT grove.merge('l', 'conflicting merge');

SELECT is(
  (SELECT e.ok FROM grove.events e WHERE e.verb = 'merge' ORDER BY e.id DESC LIMIT 1), false,
  'AC-OBS-01: a merge that stopped on conflicts is recorded as not ok');

SELECT is(
  (SELECT (e.detail ->> 'conflicts')::int FROM grove.events e
   WHERE e.verb = 'merge' ORDER BY e.id DESC LIMIT 1), 1,
  'AC-OBS-01: with the conflict count in the same event');

SELECT is(
  (SELECT value FROM grove.metrics() WHERE metric = 'grove_events_failed'), 1::numeric,
  'AC-OBS-02: metrics counts failed operations for a scraper');

SELECT cmp_ok(
  (SELECT value FROM grove.metrics() WHERE metric = 'grove_commit_ms_p50'), '>', 0::numeric,
  'AC-OBS-02: and reports commit latency percentiles from the recorded events');

UPDATE grove.meta SET value = 'off' WHERE key = 'log_events';
UPDATE ev SET v = 'quiet' WHERE id = 2;
SELECT grove.commit('while logging is off');

SELECT is(
  (SELECT count(*)::int FROM grove.events WHERE detail ->> 'sha' = grove.short_sha(grove.resolve(grove.head()))), 0,
  'AC-OBS-03: turning logging off really stops it, so it can be switched off under load');

SELECT * FROM finish();
ROLLBACK;
