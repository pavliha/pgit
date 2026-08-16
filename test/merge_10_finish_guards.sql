BEGIN;
SELECT plan(8);

CREATE TABLE t (id int PRIMARY KEY, v text);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'base'||g FROM generate_series(1,20) g;
SELECT grove.commit('base','alice');
SELECT grove.branch('feature');
SELECT grove.checkout('feature');
UPDATE t SET v = 'feature' WHERE id = 1;
SELECT grove.commit('feature edit','bob');
SELECT grove.checkout('main');
UPDATE t SET v = 'main' WHERE id = 1;
SELECT grove.commit('main edit','alice');

CREATE TEMP TABLE conflicted AS SELECT grove.merge('feature') AS n;
CREATE TEMP TABLE m AS SELECT id FROM grove.merges ORDER BY id DESC LIMIT 1;

SELECT cmp_ok((SELECT n FROM conflicted), '>', 0,
  'merge guards: merge reports conflicts, and that count is not the merge id');
SELECT cmp_ok((SELECT count(*) FROM grove.conflicts WHERE merge_id = (SELECT id FROM m) AND NOT resolved),
  '>', 0::bigint,
  'merge guards: the merge really did conflict, so the refusals below are not vacuous');

SELECT throws_like($$ SELECT grove.merge_finish((SELECT id FROM m)) $$,
  '%conflict(s) still unresolved%',
  'merge guards: finishing with a conflict outstanding is refused');

SELECT grove.resolve_conflict((SELECT id FROM m), c.tbl, c.k, 'ours')
FROM grove.conflicts c WHERE c.merge_id = (SELECT id FROM m);

SELECT is((SELECT count(*) FROM grove.conflicts
           WHERE merge_id = (SELECT id FROM m) AND NOT resolved), 0::bigint,
  'merge guards: resolving clears them');

CREATE TEMP TABLE was AS SELECT sha FROM grove.refs WHERE name = 'main';
UPDATE grove.refs SET sha = (SELECT sha FROM grove.commits WHERE message = 'base')
WHERE name = 'main';

SELECT throws_like($$ SELECT grove.merge_finish((SELECT id FROM m)) $$,
  '%moved since the merge started%',
  'merge guards: a branch that moved under the merge stops it rather than committing over the move');

UPDATE grove.refs SET sha = (SELECT sha FROM was) WHERE name = 'main';

SELECT throws_like($$ SELECT grove.merge_finish(999999) $$, '%no merge 999999 in progress%',
  'merge guards: an unknown merge id is refused');

SELECT ok(grove.merge_finish((SELECT id FROM m)) >= 0,
  'merge guards: and the merge finishes once its branch is back where it started');

SELECT is((SELECT count(*) FROM grove.merges WHERE id = (SELECT id FROM m)), 0::bigint,
  'merge guards: the finished merge is cleared, so its guards cannot be tripped again');

SELECT * FROM finish();
ROLLBACK;
