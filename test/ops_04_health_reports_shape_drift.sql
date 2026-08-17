BEGIN;
SELECT plan(8);

CREATE TABLE t (id int PRIMARY KEY, a text);
SELECT grove.track('t');
INSERT INTO t VALUES (1, 'one'), (2, 'two');
SELECT grove.commit('base', 'pavlo');
SELECT grove.branch('feature');

SELECT cmp_ok((SELECT count(*) FROM grove.health()), '>', 10::bigint,
  'AC-OPS: health reports a real surface of metrics, not a couple of them');

SELECT is((SELECT count(*)::int FROM grove.needs_attention()), 0,
  'AC-OPS: a healthy repository needs no attention, so anything below is the drift talking');

ALTER TABLE t ADD COLUMN extra text;

SELECT is((SELECT count(*)::int FROM grove.needs_attention()
           WHERE metric = 'tracked shapes changed since head'), 1,
  'AC-OPS: a live shape that no longer matches head needs attention, which used to go unmentioned');

SELECT is((SELECT value FROM grove.needs_attention()
           WHERE metric = 'tracked shapes changed since head'), 't',
  'AC-OPS: and it names the table, so the report is actionable without digging');

SELECT throws_like(
  $$ SELECT grove.checkout('feature') $$,
  '%different shape%',
  'AC-OPS: the state it reports is the state that makes checkout refuse, so it is not cosmetic');

SELECT is((SELECT count(*)::int FROM grove.drifted_shapes()), 1,
  'AC-OPS: the refusal and the report read the same drifted_shapes, rather than two queries that can disagree');

ALTER TABLE t DROP COLUMN extra;

SELECT is((SELECT count(*)::int FROM grove.needs_attention()), 0,
  'AC-OPS: putting the column back clears it, so health reads the schema rather than latching');

SELECT lives_ok(
  $$ SELECT grove.checkout('feature') $$,
  'AC-OPS: and checkout works again in the state health now calls healthy');

SELECT * FROM finish();
ROLLBACK;
