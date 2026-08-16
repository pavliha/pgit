BEGIN;
SELECT plan(25);

CREATE TABLE t (id int PRIMARY KEY, name text, hits int);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'row-'||g, 0 FROM generate_series(1,50) g;
CREATE TEMP TABLE c1 AS SELECT grove.commit('one','p','2026-01-01'::timestamptz) AS sha;
UPDATE t SET name='changed' WHERE id=5;
UPDATE t SET name='also changed' WHERE id=6;
CREATE TEMP TABLE c2 AS SELECT grove.commit('two','p','2026-06-01'::timestamptz) AS sha;

SELECT grove.tag('v1', encode((SELECT sha FROM c1),'hex'), 'first release');
SELECT is(grove.rev('v1'), (SELECT sha FROM c1), 'tag: a tag name resolves as a revision');
SELECT throws_like($$ SELECT grove.tag('v1') $$, '%already exists%',
  'tag: creating an existing tag is refused');
SELECT lives_ok($$ SELECT grove.tag('v1','HEAD',NULL,true) $$, 'tag: force moves it');
SELECT grove.tag_delete('v1');
SELECT is((SELECT count(*) FROM grove.tags), 0::bigint, 'tag: delete removes it');

SELECT is(grove.restore(encode((SELECT sha FROM c1),'hex'), 't:5'), 1,
  'restore: a single row restore touches exactly one row');
SELECT is((SELECT name FROM t WHERE id=5), 'row-5', 'restore: that row came back');
SELECT is((SELECT name FROM t WHERE id=6), 'also changed',
  'restore: the other changed row was left alone');
SELECT is(grove.resolve('main'), (SELECT sha FROM c2), 'restore: the branch did not move');

SELECT grove.restore(encode((SELECT sha FROM c2),'hex'), 't');
SELECT is((SELECT count(*) FROM grove.diff_working()), 0::bigint,
  'restore: a whole table restore brings the tree back to HEAD');

UPDATE t SET name='work in progress' WHERE id=9;
CREATE TEMP TABLE st AS SELECT grove.stash_push('wip') AS slot;
SELECT is(grove.is_dirty(), false, 'stash: the working tree is clean afterwards');
SELECT is(grove.resolve('main'), (SELECT sha FROM c2), 'stash: the branch did not move');
SELECT is((SELECT count(*) FROM grove.stash_list()), 1::bigint, 'stash: it is listed');
SELECT ok(grove.stash_pop() >= 1, 'stash: pop applied the stashed change');
SELECT is((SELECT name FROM t WHERE id=9), 'work in progress', 'stash: the change is back');
SELECT is((SELECT count(*) FROM grove.stash_list()), 0::bigint, 'stash: the slot is gone');

SELECT grove.restore(encode((SELECT sha FROM c2),'hex'), 't');

DO $$ DECLARE i int; BEGIN
  FOR i IN 3..10 LOOP
    UPDATE t SET hits = CASE WHEN i >= 6 THEN 999 ELSE i END WHERE id = 1;
    PERFORM grove.commit('c'||i, 'p', ('2026-06-0'||(i-2))::timestamptz, true);
  END LOOP;
END $$;

CREATE TEMP TABLE found (sha bytea);
DO $$
DECLARE pick bytea; prev bytea; guard int := 0;
BEGIN
  pick := grove.bisect_start('HEAD~7', 'HEAD');
  WHILE pick IS NOT NULL AND pick IS DISTINCT FROM prev AND guard < 20 LOOP
    prev := pick; guard := guard + 1;
    IF (SELECT hits FROM t WHERE id=1) = 999 THEN pick := grove.bisect_bad();
    ELSE pick := grove.bisect_good(); END IF;
  END LOOP;
  INSERT INTO found SELECT bad FROM grove.bisect;
END $$;

SELECT is((SELECT message FROM grove.commits WHERE sha = (SELECT sha FROM found)), 'c6',
  'bisect: converged on the first commit where the value went wrong');
SELECT grove.bisect_reset();

SELECT grove.reset('main','hard');
CREATE TEMP TABLE before_prune AS SELECT count(*) AS commits, (SELECT count(*) FROM grove.nodes) AS nodes
FROM grove.commits;

SELECT ok(grove.prune('2026-06-03'::timestamptz) > 0, 'prune: old commits were removed');
SELECT ok((SELECT count(*) FROM grove.commits) < (SELECT commits FROM before_prune),
  'prune: the history is shorter');
SELECT is((SELECT count(*) FROM grove.fsck()), 0::bigint,
  'prune: fsck is clean afterwards, so nothing reachable was collected');
SELECT cmp_ok((SELECT count(*) FROM grove.shallow), '>', 0::bigint,
  'prune: the parent link it severs is recorded, not silently forgotten');
SELECT is((SELECT count(*) FROM grove.commits c
           WHERE grove.recomputed_commit_sha(c.sha) IS DISTINCT FROM c.sha), 0::bigint,
  'prune: every surviving commit still hashes to its own content afterwards');
SELECT is(grove.write_tree('t'),
  (SELECT root_hash FROM grove.trees WHERE commit_sha = grove.resolve('main') AND tbl='t'),
  'prune: the surviving tip still describes the live table exactly');

CREATE TABLE bis (id int PRIMARY KEY, v text);
SELECT grove.track('bis');
INSERT INTO bis SELECT g, 'v' || g FROM generate_series(1, 10) g;
SELECT grove.commit('bis 0', 'main');
DO $$ DECLARE i int; BEGIN
  FOR i IN 1..5 LOOP
    UPDATE bis SET v = 'r' || i WHERE id = i;
    PERFORM grove.commit('bis ' || i, 'main');
  END LOOP;
END $$;

CREATE TEMP TABLE bis_tip AS SELECT grove.resolve('main') AS sha,
                                    (SELECT count(*) FROM grove.commits) AS total;

SELECT grove.bisect_start('main~4', 'main');
SELECT grove.bisect_bad('main');

SELECT isnt(
  grove.resolve('main'), (SELECT sha FROM bis_tip),
  'extras: a bisect in progress does move the branch, so the restore below is not vacuous');

SELECT grove.bisect_reset();

SELECT is(
  grove.resolve('main'), (SELECT sha FROM bis_tip),
  'extras: bisect_reset puts the branch back where bisect_start found it');

SELECT is(
  (SELECT count(*) FROM grove.log(grove.resolve('main')))::int,
  (SELECT total FROM bis_tip)::int,
  'extras: and every commit is reachable again, so gc cannot collect the tip');

SELECT * FROM finish();
ROLLBACK;
