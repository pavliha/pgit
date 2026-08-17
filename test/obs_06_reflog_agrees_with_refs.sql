BEGIN;
SELECT plan(9);

CREATE FUNCTION drifted_refs() RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int
  FROM grove.refs r
  CROSS JOIN LATERAL (SELECT g.new_sha FROM grove.reflog g
                      WHERE g.ref = r.name ORDER BY g.id DESC LIMIT 1) l
  WHERE r.sha IS DISTINCT FROM l.new_sha;
$$;

CREATE TABLE t (id int PRIMARY KEY, name text);
SELECT grove.track('t');
INSERT INTO t VALUES (1, 'one'), (2, 'two');
SELECT grove.commit('base', 'pavlo');

SELECT is(drifted_refs(), 0,
  'AC-OBS: after a commit the reflog names where the branch actually is');

SELECT grove.branch('feature');
UPDATE t SET name = 'main version' WHERE id = 2;
SELECT grove.commit('main edits row 2', 'pavlo');

SELECT is(drifted_refs(), 0, 'AC-OBS: and after a second commit on main');

SELECT grove.checkout('feature');
UPDATE t SET name = 'feature version' WHERE id = 2;
SELECT grove.commit('feature edits row 2', 'pavlo');
SELECT grove.rebase('main');

SELECT is(drifted_refs(), 0,
  'AC-OBS: a rebase that stops on a conflict still leaves the reflog truthful');

SELECT grove.rebase_abort();

SELECT is(drifted_refs(), 0,
  'AC-OBS: and so does aborting it, which used to move the branch and log nothing');

SELECT is(
  (SELECT action FROM grove.reflog WHERE ref = 'feature' ORDER BY id DESC LIMIT 1),
  'rebase abort',
  'AC-OBS: the abort names itself in the reflog, so the move is attributable');

SELECT is(
  (SELECT new_sha FROM grove.reflog WHERE ref = 'feature' ORDER BY id DESC LIMIT 1),
  grove.resolve('feature'),
  'AC-OBS: and it records the sha the branch came back to');

SELECT grove.checkout('main');
UPDATE t SET name = 'dirty' WHERE id = 1;
SELECT grove.stash_push('wip');
SELECT grove.stash_pop();

SELECT is(drifted_refs(), 0, 'AC-OBS: a stash round trip leaves every ref accounted for');

SELECT grove.reset(encode(grove.resolve('feature'), 'hex'), 'hard');

SELECT is(drifted_refs(), 0, 'AC-OBS: and so does a hard reset');

SELECT cmp_ok((SELECT count(*) FROM grove.reflog), '>=', 6::bigint,
  'AC-OBS: the oracle ran against a reflog with entries in it, not an empty table');

SELECT * FROM finish();
ROLLBACK;
