BEGIN;
SELECT plan(6);

CREATE TABLE t (id int PRIMARY KEY, a text);
SELECT grove.track('t');
INSERT INTO t VALUES (1, 'original');
SELECT grove.commit('base','alice');
SELECT grove.branch('side');
SELECT grove.checkout('side');
UPDATE t SET a = 'from the side' WHERE id = 1;
SELECT grove.commit('side change','sidney');
SELECT grove.checkout('main');
UPDATE t SET a = 'untouched by main' WHERE id = 2 AND false;
INSERT INTO t VALUES (2, 'main only');
SELECT grove.commit('main change','mainard');
SELECT grove.merge('side');

SELECT is((SELECT a FROM t WHERE id = 1), 'from the side',
  'first parent log: the merge brought the side branch value over');

SELECT is((SELECT count(*) FROM grove.log() l WHERE l.message = 'side change'), 0::bigint,
  'first parent log: log walks first parents only, so the merged commit is not listed');

SELECT is((SELECT count(*) FROM grove.ancestors(grove.resolve('main')) a
           JOIN grove.commits c ON c.sha = a.a WHERE c.message = 'side change'), 1::bigint,
  'first parent log: it is still reachable, the history holds it, log just does not walk to it');

SELECT is((SELECT count(*) FROM grove.log(NULL, 't:1') l WHERE l.message = 'merge side'), 1::bigint,
  'first parent log: a row that arrived in the merge is shown against the merge');

SELECT is((SELECT c.message FROM grove.blame('t','1') b
           JOIN grove.commits c ON c.sha = b.commit_sha WHERE b.col = 'a'), 'side change',
  'first parent log: while blame still names the commit that made the change');

SELECT is((SELECT c.message FROM grove.commits c WHERE c.sha = grove.rev('HEAD~1')), 'main change',
  'first parent log: and HEAD~1 follows the first parent too, which is what makes the walk coherent');

SELECT * FROM finish();
ROLLBACK;
