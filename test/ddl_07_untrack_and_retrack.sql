BEGIN;
SELECT plan(8);

CREATE TABLE t (id int PRIMARY KEY, v text);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'v'||g FROM generate_series(1,100) g;
SELECT grove.commit('tracked','alice');
SELECT grove.branch('side');

SELECT grove.untrack('t');
UPDATE t SET v = 'while untracked' WHERE id = 1;

SELECT is((SELECT v FROM t WHERE id = 1), 'while untracked',
  'retrack: the change really happened, grove was just not watching');
SELECT is((SELECT count(*) FROM grove.changes WHERE commit_sha IS NULL), 0::bigint,
  'retrack: and the journal never saw it, because untrack drops the triggers');

SELECT grove.track('t');

SELECT is((SELECT count(*) FROM grove.changes WHERE commit_sha IS NULL), 0::bigint,
  'retrack: re-tracking does not invent journal rows for what it missed');
SELECT ok(grove.is_dirty(),
  'retrack: but the table no longer matches its commit, and grove says so from the tree, not the journal');

SELECT ok(grove.commit('after retrack','bob') IS NOT NULL,
  'retrack: so the drift can be committed rather than being lost');
SELECT is(grove.write_tree('t'),
  (SELECT root_hash FROM grove.trees WHERE commit_sha = grove.resolve('main') AND tbl = 't'),
  'retrack: and the tree that commit recorded matches a full rebuild');
SELECT is((SELECT count(*) FROM grove.fsck()), 0::bigint,
  'retrack: the store is clean afterwards');

SELECT grove.checkout('side', true);
SELECT is((SELECT v FROM t WHERE id = 1), 'v1',
  'retrack: and history from before the untrack still restores');

SELECT * FROM finish();
ROLLBACK;
