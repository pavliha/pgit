BEGIN;
SELECT plan(6);

CREATE TABLE t (id int PRIMARY KEY, name text);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'row-'||g FROM generate_series(1,200) g;
SELECT grove.commit('before the rename','alice');
SELECT grove.branch('side');

ALTER TABLE t RENAME TO u;
UPDATE u SET name = 'changed' WHERE id = 1;

SELECT ok(grove.commit('after the rename','bob') IS NOT NULL,
  'rename: renaming a tracked table and committing is supported, history records the new name');

SELECT is((SELECT r.new_tbl FROM grove.table_renames(grove.rev('HEAD~1'), grove.rev('HEAD')) r
           WHERE r.old_tbl = 't'), 'u',
  'rename: and the rename is detectable across the two commits');

SELECT throws_like($$ SELECT grove.checkout('side', true) $$,
  '%needs a table called t, which this database does not have%',
  'rename: checking out earlier history names the table it is missing, not a bare relation error');

ALTER TABLE u RENAME TO t;

SELECT throws_like($$ SELECT grove.checkout('side', true) $$,
  '%needs a table called u, which this database does not have%',
  'rename: renaming back is not enough either, the commit being left behind names the other one');

CREATE TABLE u (id int PRIMARY KEY, name text);

SELECT ok(grove.checkout('side', true) >= 0,
  'rename: with both names present the checkout runs, which is what the message asks for');

SELECT is((SELECT count(*) FROM t), 200::bigint,
  'rename: and the rows from before the rename come back');

SELECT * FROM finish();
ROLLBACK;
