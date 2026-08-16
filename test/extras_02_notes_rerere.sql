BEGIN;
SELECT plan(16);

CREATE TABLE t (id int PRIMARY KEY, v text);
SELECT grove.track('t');
INSERT INTO t VALUES (1,'orig'),(2,'orig');
SELECT grove.commit('base','p');

SELECT grove.note_add('HEAD', 'reviewed by ops, safe to ship');
SELECT is(grove.note_show('HEAD'), 'reviewed by ops, safe to ship', 'notes: attach and read');
SELECT grove.note_add('HEAD', 'revised note');
SELECT is(grove.note_show('HEAD'), 'revised note', 'notes: re-adding replaces');
SELECT grove.note_delete('HEAD');
SELECT is(grove.note_show('HEAD'), NULL, 'notes: delete removes it');

SELECT grove.branch('f1');
UPDATE t SET v='main' WHERE id=1;
SELECT grove.commit('main edit','p');
SELECT grove.checkout('f1');
UPDATE t SET v='feature' WHERE id=1;
SELECT grove.commit('feature edit','p');

CREATE TEMP TABLE m1 AS SELECT grove.merge('main') AS n;
SELECT is((SELECT n FROM m1), 1, 'rerere: the first merge conflicts as usual');

SELECT is((SELECT count(*) FROM grove.rerere), 0::bigint, 'rerere: nothing learned yet');

SELECT grove.resolve_conflict((SELECT id FROM grove.merges), 't',
  (SELECT k FROM grove.conflicts LIMIT 1), 'theirs');
SELECT grove.merge_finish((SELECT id FROM grove.merges));

SELECT is((SELECT count(*) FROM grove.rerere), 1::bigint,
  'rerere: finishing the merge recorded the resolution');
SELECT is((SELECT resolution_kind FROM grove.rerere), 'theirs',
  'rerere: it recorded which side was chosen');

UPDATE t SET v='orig' WHERE id=1;
SELECT grove.commit('back to the same base','p');
SELECT grove.branch('g1');
SELECT grove.branch('g2');

SELECT grove.checkout('g2');
UPDATE t SET v='main' WHERE id=1;
SELECT grove.commit('the same main edit again','p');

SELECT grove.checkout('g1');
UPDATE t SET v='feature' WHERE id=1;
SELECT grove.commit('the same feature edit again','p');

CREATE TEMP TABLE m2 AS SELECT grove.merge('g2') AS n;

SELECT ok((SELECT used FROM grove.rerere LIMIT 1) >= 1,
  'rerere: the recorded resolution was actually consulted, so the next check is not vacuous');
SELECT is((SELECT n FROM m2), 0,
  'rerere: the identical conflict resolved itself without stopping');
SELECT is((SELECT v FROM t WHERE id=1), 'main',
  'rerere: it applied the same choice as last time');

CREATE TABLE renamed_probe (id int PRIMARY KEY, v text);
SELECT grove.track('renamed_probe');
INSERT INTO renamed_probe VALUES (1,'x');
CREATE TEMP TABLE rp1 AS SELECT grove.commit('probe','p') AS sha;
SELECT grove.untrack('renamed_probe');
ALTER TABLE renamed_probe RENAME TO renamed_probe2;
SELECT grove.track('renamed_probe2');
CREATE TEMP TABLE rp2 AS SELECT grove.commit('probe renamed','p') AS sha;

SELECT is(
  (SELECT old_tbl || '->' || new_tbl || ':' || kind
   FROM grove.table_renames((SELECT sha FROM rp1), (SELECT sha FROM rp2))),
  'renamed_probe->renamed_probe2:identical',
  'table renames: a renamed table is detected by its identical tree root');

SELECT throws_like(
  format($$ SELECT grove.assert_same_schema(%L::bytea, %L::bytea) $$,
         (SELECT sha FROM rp1), (SELECT sha FROM rp2)),
  '%looks renamed to%',
  'table renames: replaying across one fails with a message naming both tables');

CREATE TABLE ren_a (id int PRIMARY KEY, v text);
SELECT grove.track('ren_a');
INSERT INTO ren_a SELECT g, 'v' || g FROM generate_series(1,10) g;
CREATE TEMP TABLE ra1 AS SELECT grove.commit('ren a','p') AS sha;
SELECT grove.untrack('ren_a');
ALTER TABLE ren_a RENAME TO ren_b;
UPDATE ren_b SET v = 'changed' WHERE id <= 2;
SELECT grove.track('ren_b');
CREATE TEMP TABLE ra2 AS SELECT grove.commit('ren b edited','p') AS sha;

SELECT is(
  (SELECT old_tbl || '->' || new_tbl || ':' || kind
   FROM grove.table_renames((SELECT sha FROM ra1), (SELECT sha FROM ra2))),
  'ren_a->ren_b:similar',
  'table renames: a rename plus an edit is still detected, as similar rather than identical');

SELECT is(
  (SELECT similarity FROM grove.table_renames((SELECT sha FROM ra1), (SELECT sha FROM ra2))),
  0.8000::numeric,
  'table renames: 8 of 10 rows unchanged scores 0.8, so the number is not a placeholder');

SELECT is(
  (SELECT count(*) FROM grove.table_renames((SELECT sha FROM ra1), (SELECT sha FROM ra2), 0.9)),
  0::bigint,
  'table renames: raising the threshold above the score drops the pair');

CREATE TABLE zz_a (id int PRIMARY KEY, v text);
CREATE TABLE zz_b (id int PRIMARY KEY, v text);
SELECT grove.track('zz_a');
INSERT INTO zz_a VALUES (1,'aaa');
CREATE TEMP TABLE za1 AS SELECT grove.commit('zz a','p') AS sha;
SELECT grove.untrack('zz_a');
SELECT grove.track('zz_b');
INSERT INTO zz_b VALUES (9,'bbb');
CREATE TEMP TABLE za2 AS SELECT grove.commit('zz b','p') AS sha;

SELECT is(
  (SELECT count(*) FROM grove.table_renames((SELECT sha FROM za1), (SELECT sha FROM za2))),
  0::bigint,
  'table renames: a drop and an unrelated add sharing no rows is not called a rename');

SELECT * FROM finish();
ROLLBACK;
