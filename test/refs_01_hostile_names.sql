BEGIN;
SELECT plan(13);

CREATE TABLE t (id int PRIMARY KEY, a text);
SELECT grove.track('t');
INSERT INTO t VALUES (1, 'v0');
SELECT grove.commit('c1', 'pavlo', '2020-01-01'::timestamptz);
UPDATE t SET a = 'v1';
SELECT grove.commit('c2', 'pavlo', '2020-01-02'::timestamptz);

SELECT isnt(grove.rev('main^'), grove.resolve('main'),
  'AC-REFS: rev reads a trailing caret as revision syntax, which is why a branch cannot be named that way');

SELECT throws_like(
  $$ SELECT grove.branch('main^') $$,
  '%revision syntax%',
  'AC-REFS: a branch name containing a caret is refused, and says why');

SELECT throws_like(
  $$ SELECT grove.branch('HEAD~1') $$,
  '%revision syntax%',
  'AC-REFS: so is one containing a tilde');

SELECT throws_like(
  $$ SELECT grove.branch('feature:x') $$,
  '%revision syntax%',
  'AC-REFS: and one containing a colon, which a pathspec would read as a row key');

SELECT throws_like(
  $$ SELECT grove.branch('HEAD') $$,
  '%reserved%',
  'AC-REFS: HEAD itself is reserved, since a branch by that name could never be resolved');

SELECT throws_like(
  $$ SELECT grove.branch('stash/9') $$,
  '%reserved for grove%',
  'AC-REFS: the stash namespace is refused, where such a branch used to be popped and deleted by stash pop');

SELECT throws_like(
  $$ SELECT grove.branch('remotes/origin/main') $$,
  '%reserved for grove%',
  'AC-REFS: and so is the remote tracking namespace');

SELECT throws_like(
  $$ SELECT grove.branch('') $$,
  '%cannot be empty%',
  'AC-REFS: an empty branch name is refused');

SELECT throws_like(
  $$ SELECT grove.branch('with space') $$,
  '%whitespace%',
  'AC-REFS: and one with whitespace in it');

SELECT lives_ok(
  $$ SELECT grove.branch('feature/nested-name') $$,
  'AC-REFS: an ordinary name with a slash and a dash is still fine');

SELECT throws_like(
  $$ SELECT grove.tag('v1^') $$,
  '%revision syntax%',
  'AC-REFS: tags are validated the same way, since rev resolves them too');

SELECT throws_like(
  $$ SELECT grove.remote_add('a/b', 'http://example.invalid') $$,
  '%cannot contain a slash%',
  'AC-REFS: a remote name cannot contain a slash, because it becomes part of a tracking ref name');

UPDATE t SET a = 'wip';
SELECT grove.stash_push('my work');
SELECT grove.stash_pop();

SELECT is((SELECT a FROM t WHERE id = 1), 'wip',
  'AC-REFS: stash push and pop still use the stash namespace themselves, so reserving it broke nothing');

SELECT * FROM finish();
ROLLBACK;
