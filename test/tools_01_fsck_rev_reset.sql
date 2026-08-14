BEGIN;
SELECT plan(23);

CREATE TABLE t (id int PRIMARY KEY, name text, hits int);
SELECT pgit.track('t');
INSERT INTO t SELECT g, 'row-'||g, 0 FROM generate_series(1,200) g;
CREATE TEMP TABLE c1 AS SELECT pgit.commit('one','p') AS sha;
UPDATE t SET hits=1 WHERE id=5;
CREATE TEMP TABLE c2 AS SELECT pgit.commit('two','p') AS sha;
UPDATE t SET hits=2 WHERE id=6;
CREATE TEMP TABLE c3 AS SELECT pgit.commit('three','q') AS sha;

SELECT is((SELECT count(*) FROM pgit.fsck()), 0::bigint,
  'fsck: a healthy repository reports no problems');

SELECT pgit.repack(50);
SELECT is((SELECT count(*) FROM pgit.fsck()), 0::bigint,
  'fsck: still clean after packing into delta chains, so chains verify end to end');

SELECT is(pgit.rev('HEAD'), (SELECT sha FROM c3), 'rev: HEAD');
SELECT is(pgit.rev('HEAD~1'), (SELECT sha FROM c2), 'rev: HEAD~1 walks one parent');
SELECT is(pgit.rev('HEAD~2'), (SELECT sha FROM c1), 'rev: HEAD~2 walks two');
SELECT is(pgit.rev('HEAD^'), (SELECT sha FROM c2), 'rev: caret is the first parent');
SELECT is(pgit.rev('main'), (SELECT sha FROM c3), 'rev: a branch name resolves');
SELECT is(pgit.rev(pgit.short_sha((SELECT sha FROM c1))), (SELECT sha FROM c1),
  'rev: an abbreviated sha resolves');
SELECT throws_like($$ SELECT pgit.rev('HEAD~99') $$, '%past the root%',
  'rev: walking past the root fails clearly');

SELECT is((SELECT count(*) FROM pgit.log(NULL, NULL, 2)), 2::bigint,
  'log: max_count limits the walk');
SELECT is((SELECT count(*) FROM pgit.log(NULL, NULL, NULL, NULL, 'q')), 1::bigint,
  'log: the author filter selects one commit');

SELECT ok((SELECT count(*) FROM pgit.reflog WHERE ref='main') >= 3,
  'reflog: every ref movement was recorded');

UPDATE t SET name='uncommitted' WHERE id=9;

SELECT is((SELECT count(*) FROM pgit.diff_working()), 1::bigint,
  'diff_working: an uncommitted change shows against HEAD');
SELECT is((SELECT after->>'name' FROM pgit.diff_working()), 'uncommitted',
  'diff_working: it carries the live value');

UPDATE t SET name='row-9' WHERE id=9;
SELECT is((SELECT count(*) FROM pgit.diff_working()), 0::bigint,
  'diff_working: nothing to report once the tree matches HEAD again');

SELECT ok(pgit.reset('HEAD~1', 'hard') >= 1, 'reset --hard rewrote the working tree');
SELECT is(pgit.resolve('main'), (SELECT sha FROM c2), 'reset --hard moved the branch');
SELECT is((SELECT hits FROM t WHERE id=6), 0, 'reset --hard restored the content');

UPDATE t SET name='scribbled over' WHERE id=11;
SELECT is((SELECT count(*) FROM pgit.diff_working()), 1::bigint,
  'reset: the working tree is dirty before the reset');
SELECT pgit.reset('HEAD', 'hard');
SELECT is((SELECT count(*) FROM pgit.diff_working()), 0::bigint,
  'reset --hard HEAD discards uncommitted changes, comparing the live tree rather than two refs');

SELECT pgit.unpack();

CREATE TEMP TABLE victim AS
  SELECT hash, entries FROM pgit.nodes WHERE level = 0 AND entries IS NOT NULL LIMIT 1;

-- A node's identity is its packed child hashes; corrupting one is what fsck has
-- to catch. It used to live as hex inside the entries array.
UPDATE pgit.nodes SET hashes = overlay(hashes placing '\xdeadbeef'::bytea from 1 for 4)
WHERE hash = (SELECT hash FROM victim);

SELECT is(
  (SELECT count(*) FROM pgit.fsck() WHERE problem = 'node hash mismatch'), 1::bigint,
  'fsck: a tampered node is caught by recomputing its hash from its children');

SELECT is(
  (SELECT count(*) FROM pgit.fsck() WHERE problem = 'child node missing'), 0::bigint,
  'fsck: the tampered leaf is not also reported as a missing child, since leaves have no children');

UPDATE pgit.nodes SET entries = (SELECT entries FROM victim) WHERE hash = (SELECT hash FROM victim);

INSERT INTO pgit.nodes (hash, level, base_hash, delta)
VALUES ('\xfeed'::bytea, 0, '\xf00d'::bytea, '{"p":0,"s":0,"m":"[]"}'::jsonb);

SELECT is(
  (SELECT count(*) FROM pgit.fsck() WHERE problem = 'delta base missing'), 1::bigint,
  'fsck: a delta pointing at a base that is not there is caught');

SELECT * FROM finish();
ROLLBACK;
