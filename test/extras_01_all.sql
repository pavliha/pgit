BEGIN;
SELECT plan(20);

CREATE TABLE t (id int PRIMARY KEY, name text, hits int);
SELECT pgit.track('t');
INSERT INTO t SELECT g, 'row-'||g, 0 FROM generate_series(1,50) g;
CREATE TEMP TABLE c1 AS SELECT pgit.commit('one','p','2026-01-01'::timestamptz) AS sha;
UPDATE t SET name='changed' WHERE id=5;
UPDATE t SET name='also changed' WHERE id=6;
CREATE TEMP TABLE c2 AS SELECT pgit.commit('two','p','2026-06-01'::timestamptz) AS sha;

SELECT pgit.tag('v1', encode((SELECT sha FROM c1),'hex'), 'first release');
SELECT is(pgit.rev('v1'), (SELECT sha FROM c1), 'tag: a tag name resolves as a revision');
SELECT throws_like($$ SELECT pgit.tag('v1') $$, '%already exists%',
  'tag: creating an existing tag is refused');
SELECT lives_ok($$ SELECT pgit.tag('v1','HEAD',NULL,true) $$, 'tag: force moves it');
SELECT pgit.tag_delete('v1');
SELECT is((SELECT count(*) FROM pgit.tags), 0::bigint, 'tag: delete removes it');

SELECT is(pgit.restore(encode((SELECT sha FROM c1),'hex'), 't:5'), 1,
  'restore: a single row restore touches exactly one row');
SELECT is((SELECT name FROM t WHERE id=5), 'row-5', 'restore: that row came back');
SELECT is((SELECT name FROM t WHERE id=6), 'also changed',
  'restore: the other changed row was left alone');
SELECT is(pgit.resolve('main'), (SELECT sha FROM c2), 'restore: the branch did not move');

SELECT pgit.restore(encode((SELECT sha FROM c2),'hex'), 't');
SELECT is((SELECT count(*) FROM pgit.diff_working()), 0::bigint,
  'restore: a whole table restore brings the tree back to HEAD');

UPDATE t SET name='work in progress' WHERE id=9;
CREATE TEMP TABLE st AS SELECT pgit.stash_push('wip') AS slot;
SELECT is(pgit.is_dirty(), false, 'stash: the working tree is clean afterwards');
SELECT is(pgit.resolve('main'), (SELECT sha FROM c2), 'stash: the branch did not move');
SELECT is((SELECT count(*) FROM pgit.stash_list()), 1::bigint, 'stash: it is listed');
SELECT ok(pgit.stash_pop() >= 1, 'stash: pop applied the stashed change');
SELECT is((SELECT name FROM t WHERE id=9), 'work in progress', 'stash: the change is back');
SELECT is((SELECT count(*) FROM pgit.stash_list()), 0::bigint, 'stash: the slot is gone');

SELECT pgit.restore(encode((SELECT sha FROM c2),'hex'), 't');

DO $$ DECLARE i int; BEGIN
  FOR i IN 3..10 LOOP
    UPDATE t SET hits = CASE WHEN i >= 6 THEN 999 ELSE i END WHERE id = 1;
    PERFORM pgit.commit('c'||i, 'p', ('2026-06-0'||(i-2))::timestamptz);
  END LOOP;
END $$;

CREATE TEMP TABLE found (sha bytea);
DO $$
DECLARE pick bytea; prev bytea; guard int := 0;
BEGIN
  pick := pgit.bisect_start('HEAD~7', 'HEAD');
  WHILE pick IS NOT NULL AND pick IS DISTINCT FROM prev AND guard < 20 LOOP
    prev := pick; guard := guard + 1;
    IF (SELECT hits FROM t WHERE id=1) = 999 THEN pick := pgit.bisect_bad();
    ELSE pick := pgit.bisect_good(); END IF;
  END LOOP;
  INSERT INTO found SELECT bad FROM pgit.bisect;
END $$;

SELECT is((SELECT message FROM pgit.commits WHERE sha = (SELECT sha FROM found)), 'c6',
  'bisect: converged on the first commit where the value went wrong');
SELECT pgit.bisect_reset();

SELECT pgit.reset('main','hard');
CREATE TEMP TABLE before_prune AS SELECT count(*) AS commits, (SELECT count(*) FROM pgit.nodes) AS nodes
FROM pgit.commits;

SELECT ok(pgit.prune('2026-06-03'::timestamptz) > 0, 'prune: old commits were removed');
SELECT ok((SELECT count(*) FROM pgit.commits) < (SELECT commits FROM before_prune),
  'prune: the history is shorter');
SELECT is((SELECT count(*) FROM pgit.fsck()), 0::bigint,
  'prune: fsck is clean afterwards, so nothing reachable was collected');
SELECT is(pgit.write_tree('t'),
  (SELECT root_hash FROM pgit.trees WHERE commit_sha = pgit.resolve('main') AND tbl='t'),
  'prune: the surviving tip still describes the live table exactly');

SELECT * FROM finish();
ROLLBACK;
