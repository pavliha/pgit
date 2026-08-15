BEGIN;
SELECT plan(8);

CREATE TABLE keep (id int PRIMARY KEY, v text NOT NULL);
CREATE TABLE gone (id int PRIMARY KEY, v text NOT NULL);
INSERT INTO keep SELECT g, 'k' || g FROM generate_series(1, 300) g;
INSERT INTO gone SELECT g, 'g' || g FROM generate_series(1, 300) g;
SELECT pgit.track('keep');
SELECT pgit.track('gone');
SELECT pgit.commit('both tables');

SELECT is(
  (SELECT t.name_at_track FROM pgit.tracked t WHERE t.name_at_track = 'gone'), 'gone',
  'AC-DDL-02: tracking records the table name, not only its oid');

DROP TABLE gone;

SELECT is(
  (SELECT m.gone_table FROM pgit.missing_tracked() m), 'gone',
  'AC-DDL-02: a tracked table dropped by a migration is still identifiable by name');

SELECT is(
  (SELECT f.detail FROM pgit.fsck() f WHERE f.problem = 'tracked table no longer exists'), 'gone',
  'AC-DDL-02: fsck reports it rather than passing clean');

SELECT ok(
  EXISTS (SELECT 1 FROM pgit.needs_attention() WHERE metric = 'tracked tables missing'),
  'AC-DDL-02: and needs_attention surfaces it, so a monitor cannot miss it');

UPDATE keep SET v = 'changed' WHERE id = 1;

SELECT throws_ok(
  $$ SELECT pgit.commit('after the drop') $$,
  NULL, NULL,
  'AC-DDL-02: committing refuses rather than silently versioning nothing');

SELECT is(
  pgit.untrack_missing(), 1,
  'AC-DDL-02: untrack_missing clears exactly the entries whose table is gone');

SELECT isnt(
  pgit.commit('after the drop'), NULL,
  'AC-DDL-02: and committing works again immediately afterwards');

SELECT cmp_ok(
  (SELECT count(*)::int FROM pgit.trees WHERE tbl = 'gone'), '>', 0,
  'AC-DDL-02: the dropped table keeps its recorded history, so it can still be read back');

SELECT * FROM finish();
ROLLBACK;
