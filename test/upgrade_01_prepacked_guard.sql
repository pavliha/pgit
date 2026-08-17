BEGIN;
SELECT plan(6);

CREATE TABLE t (id int PRIMARY KEY, v text);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'v' || g FROM generate_series(1, 300) g;
SELECT grove.commit('base', 'pavlo');

SELECT cmp_ok((SELECT count(*) FROM grove.nodes WHERE entries IS NOT NULL), '>', 1::bigint,
  'AC-UPGRADE: the fixture built stored nodes, so there is something for the guard to look at');

SELECT lives_ok(
  $$ SELECT grove.assert_readable_format() $$,
  'AC-UPGRADE: a store in the current format is readable');

ALTER TABLE grove.nodes DROP CONSTRAINT nodes_stored_or_delta;
UPDATE grove.nodes SET keys = NULL WHERE entries IS NOT NULL;

SELECT throws_like(
  $$ SELECT grove.assert_readable_format() $$,
  '%pre-packed format%',
  'AC-UPGRADE: a store from the pre-packed format is refused rather than half migrated');

SELECT throws_like(
  $$ SELECT grove.assert_readable_format() $$,
  '%DROP SCHEMA grove CASCADE%',
  'AC-UPGRADE: and the message names the recovery that works, not one the install has already deleted');

SELECT throws_like(
  $$ SELECT grove.assert_readable_format() $$,
  '%source of truth%',
  'AC-UPGRADE: and says the tables survive, since the recovery discards recorded history');

DELETE FROM grove.nodes;

SELECT lives_ok(
  $$ SELECT grove.assert_readable_format() $$,
  'AC-UPGRADE: an empty node store is not mistaken for an old one, so a fresh install proceeds');

SELECT * FROM finish();
ROLLBACK;
