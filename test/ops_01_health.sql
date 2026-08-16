BEGIN;
SELECT plan(7);

SELECT is(
  (SELECT value FROM grove.meta WHERE key = 'format_version'), '4',
  'AC-OPS-01: the database records the on-disk format it was written with');

CREATE TABLE h (id int PRIMARY KEY, v text);
SELECT grove.track('h');
INSERT INTO h SELECT g, 'v' || g FROM generate_series(1, 3000) g;
SELECT grove.commit('health base', 'main');

SELECT is(
  (SELECT count(*) FROM grove.needs_attention())::int, 0,
  'AC-OPS-01: a healthy database asks for no attention');

SELECT is(
  (SELECT value FROM grove.health() WHERE metric = 'tracked tables'), '1',
  'AC-OPS-01: health counts the tracked tables');

SELECT is(
  (SELECT value FROM grove.health() WHERE metric = 'fsck problems'), '0',
  'AC-OPS-01: and reports fsck');

SELECT isnt(
  (SELECT value FROM grove.health() WHERE metric = 'node store'), NULL,
  'AC-OPS-01: and the size of the node store, so growth can be watched');

INSERT INTO h SELECT g, 'v' || g FROM generate_series(3001, 3200) g;

SELECT cmp_ok(
  (SELECT value FROM grove.health() WHERE metric = 'journal awaiting commit')::int, '>', 0,
  'AC-OPS-01: uncommitted rows show as a journal backlog');

SELECT grove.commit('health after', 'main');

SELECT is(
  (SELECT value FROM grove.health() WHERE metric = 'journal awaiting commit'), '0',
  'AC-OPS-01: and the backlog clears when they are committed');

SELECT * FROM finish();
ROLLBACK;
