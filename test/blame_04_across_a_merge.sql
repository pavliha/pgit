BEGIN;
SELECT plan(9);

CREATE ROLE blame_sidney;
CREATE TABLE t (id int PRIMARY KEY, a text, b text);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'a'||g, 'b'||g FROM generate_series(1,10) g;
SELECT grove.commit('base','alice');
SELECT grove.grant_write('blame_sidney');
GRANT ALL ON t TO blame_sidney;

SELECT grove.branch('side');
SELECT grove.checkout('side');

SET ROLE blame_sidney;
UPDATE t SET a = 'sidney wrote this' WHERE id = 1;
RESET ROLE;

SELECT is((SELECT ch.actor FROM grove.changes ch
           WHERE ch.tbl = 't' AND ch.commit_sha IS NULL ORDER BY ch.id DESC LIMIT 1),
  'blame_sidney',
  'blame across a merge: the journal caught who actually wrote the row');

SELECT grove.commit('side changes a','sidney');
SELECT grove.checkout('main');
UPDATE t SET b = 'changed on main' WHERE id = 2;
SELECT grove.commit('main changes b','mainard');

SELECT is((SELECT a FROM t WHERE id = 1), 'a1',
  'blame across a merge: before merging, main still has the original value');

SELECT grove.merge('side');

SELECT is((SELECT a FROM t WHERE id = 1), 'sidney wrote this',
  'blame across a merge: the merge brought the value over');

SELECT is((SELECT b.actor FROM grove.blame('t','1') b WHERE b.col = 'a'), 'blame_sidney',
  'blame across a merge: and blame still credits who wrote it, not who merged it');

SELECT is((SELECT c.message FROM grove.blame('t','1') b
           JOIN grove.commits c ON c.sha = b.commit_sha WHERE b.col = 'a'), 'side changes a',
  'blame across a merge: naming the commit the change was made in, not the merge');

SELECT ok((SELECT b.exact FROM grove.blame('t','1') b WHERE b.col = 'a'),
  'blame across a merge: and saying so exactly, because the journal still holds the original write');

SELECT cmp_ok((SELECT count(*) FROM grove.changes ch WHERE ch.source = 'replay'), '>', 0::bigint,
  'blame across a merge: the merge did write journal rows, they are just labelled as replay');

CREATE TABLE u (id int PRIMARY KEY, a text);
SELECT grove.track('u');
INSERT INTO u VALUES (1, 'original');
SELECT grove.commit('u base','alice');
SELECT grove.branch('u_side');
SELECT grove.checkout('u_side');
UPDATE u SET a = 'theirs' WHERE id = 1;
SELECT grove.commit('u side','sidney');
SELECT grove.checkout('main');
UPDATE u SET a = 'ours' WHERE id = 1;
SELECT grove.commit('u main','mainard');
SELECT grove.merge('u_side');

CREATE TEMP TABLE cm AS SELECT max(id) AS id FROM grove.merges;
SELECT grove.resolve_conflict((SELECT id FROM cm), 'u',
  (SELECT k FROM grove.conflicts WHERE merge_id = (SELECT id FROM cm) LIMIT 1),
  'custom', '{"id":1,"a":"a value nobody wrote"}'::jsonb);
SELECT grove.merge_finish((SELECT id FROM cm));

SELECT is((SELECT a FROM u WHERE id = 1), 'a value nobody wrote',
  'blame across a merge: a custom resolution puts a value in that no branch ever held');
SELECT is((SELECT c.message FROM grove.blame('u','1') b
           JOIN grove.commits c ON c.sha = b.commit_sha WHERE b.col = 'a'), 'merge u_side',
  'blame across a merge: and that one is credited to the merge, which is where it was decided');

SELECT * FROM finish();
ROLLBACK;
