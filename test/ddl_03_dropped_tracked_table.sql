BEGIN;
SELECT plan(8);

CREATE TABLE keep (id int PRIMARY KEY, v text NOT NULL);
CREATE TABLE gone (id int PRIMARY KEY, v text NOT NULL);
INSERT INTO keep SELECT g, 'k' || g FROM generate_series(1, 300) g;
INSERT INTO gone SELECT g, 'g' || g FROM generate_series(1, 300) g;
SELECT grove.track('keep');
SELECT grove.track('gone');
SELECT grove.commit('both tables');

SELECT is(
  (SELECT t.name_at_track FROM grove.tracked t WHERE t.name_at_track = 'gone'), 'gone',
  'AC-DDL-02: tracking records the table name, not only its oid');

DROP TABLE gone;

SELECT is(
  (SELECT m.gone_table FROM grove.missing_tracked() m), 'gone',
  'AC-DDL-02: a tracked table dropped by a migration is still identifiable by name');

SELECT is(
  (SELECT f.detail FROM grove.fsck() f WHERE f.problem = 'tracked table no longer exists'), 'gone',
  'AC-DDL-02: fsck reports it rather than passing clean');

SELECT ok(
  EXISTS (SELECT 1 FROM grove.needs_attention() WHERE metric = 'tracked tables missing'),
  'AC-DDL-02: and needs_attention surfaces it, so a monitor cannot miss it');

UPDATE keep SET v = 'changed' WHERE id = 1;

SELECT throws_ok(
  $$ SELECT grove.commit('after the drop') $$,
  NULL, NULL,
  'AC-DDL-02: committing refuses rather than silently versioning nothing');

SELECT is(
  grove.untrack_missing(), 1,
  'AC-DDL-02: untrack_missing clears exactly the entries whose table is gone');

SELECT isnt(
  grove.commit('after the drop'), NULL,
  'AC-DDL-02: and committing works again immediately afterwards');

SELECT cmp_ok(
  (SELECT count(*)::int FROM grove.trees WHERE tbl = 'gone'), '>', 0,
  'AC-DDL-02: the dropped table keeps its recorded history, so it can still be read back');

SELECT * FROM finish();
ROLLBACK;
