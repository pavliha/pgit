BEGIN;
SELECT plan(12);

CREATE TABLE t (id int PRIMARY KEY, a text);
SELECT grove.track('t');
INSERT INTO t VALUES (1, 'v0'), (2, 'other');
SELECT grove.commit('c1', 'pavlo', '2020-01-01'::timestamptz);
UPDATE t SET a = 'v1' WHERE id = 1;
SELECT grove.commit('c2', 'pavlo', '2020-02-01'::timestamptz);
UPDATE t SET a = 'v2' WHERE id = 1;
SELECT grove.commit('c3', 'pavlo', '2020-03-01'::timestamptz);
UPDATE t SET a = 'v3' WHERE id = 1;
SELECT grove.commit('c4', 'pavlo', '2020-04-01'::timestamptz);
UPDATE t SET a = 'v4' WHERE id = 1;
SELECT grove.commit('c5', 'pavlo', '2020-05-01'::timestamptz);

SELECT grove.bisect_start(
  encode((SELECT sha FROM grove.commits WHERE message = 'c1'), 'hex'),
  encode((SELECT sha FROM grove.commits WHERE message = 'c5'), 'hex'));

SELECT isnt((SELECT message FROM grove.commits WHERE sha = grove.resolve('main')), 'c5',
  'AC-TOOLS: a bisect parks the branch off its tip, which is what puts the tip at risk');

SELECT cmp_ok(grove.prune('2020-03-01'::timestamptz), '>', 0,
  'AC-TOOLS: prune still removes commits while a bisect is open, it is not simply refusing');

SELECT is((SELECT count(*)::int FROM grove.commits WHERE message = 'c5'), 1,
  'AC-TOOLS: but the branch tip survives, where prune used to delete it for being unreachable');

SELECT is((SELECT count(*)::int FROM grove.fsck()), 0,
  'AC-TOOLS: and the store is consistent afterwards');

SELECT lives_ok(
  $$ SELECT grove.bisect_reset() $$,
  'AC-TOOLS: bisect reset does not raise, which it did once prune had deleted the commit it restores');


SELECT is((SELECT message FROM grove.commits WHERE sha = grove.resolve('main')), 'c5',
  'AC-TOOLS: bisect reset puts the branch back on its tip, which used to raise a missing commit');

SELECT is((SELECT a FROM t WHERE id = 1), 'v4',
  'AC-TOOLS: and the live table holds the tip data again, not the midpoint it was parked on');

SELECT grove.branch('feature');
UPDATE t SET a = 'main version' WHERE id = 2;
SELECT grove.commit('main edits row 2', 'pavlo', '2020-06-01'::timestamptz);
SELECT grove.checkout('feature');
UPDATE t SET a = 'feature version' WHERE id = 2;
SELECT grove.commit('feature edits row 2', 'pavlo', '2020-06-02'::timestamptz);
SELECT grove.rebase('main');

SELECT cmp_ok((SELECT count(*) FROM grove.rebase_state), '=', 1::bigint,
  'AC-TOOLS: the rebase parked on a conflict, so there is state to protect');

SELECT grove.prune('2020-06-01'::timestamptz);

SELECT lives_ok(
  $$ SELECT grove.rebase_abort() $$,
  'AC-TOOLS: a prune during a parked rebase leaves abort still able to reach the original commit');

SELECT grove.checkout('main');
SELECT grove.branch('later');
UPDATE t SET a = 'main again' WHERE id = 2;
SELECT grove.commit('main later', 'pavlo', '2020-07-01'::timestamptz);
SELECT grove.checkout('later');
UPDATE t SET a = 'later version' WHERE id = 2;
SELECT grove.commit('later edits', 'pavlo', '2020-07-02'::timestamptz);
SELECT grove.checkout('main');
SELECT grove.merge('later');

SELECT cmp_ok((SELECT count(*) FROM grove.merges), '=', 1::bigint,
  'AC-TOOLS: the merge stopped with conflicts, so there is merge state to protect');

SELECT grove.delete_branch('later');
SELECT grove.prune('2020-07-03'::timestamptz);

SELECT is((SELECT count(DISTINCT c.sha)::int FROM grove.commits c JOIN grove.merges m
           ON c.sha IN (m.ours_sha, m.theirs_sha, m.base_sha)), 3,
  'AC-TOOLS: deleting the merged branch then pruning still leaves all three commits the merge names');

SELECT cmp_ok((SELECT count(*) FROM grove.diff((SELECT base_sha FROM grove.merges),
                                               (SELECT theirs_sha FROM grove.merges))), '>', 0::bigint,
  'AC-TOOLS: and the merge can still read that history, not merely name it');

SELECT * FROM finish();
ROLLBACK;
