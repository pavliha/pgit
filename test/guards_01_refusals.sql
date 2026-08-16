BEGIN;
SELECT plan(14);

SELECT throws_like($$ SELECT grove.branch('nope') $$, '%nothing committed yet%',
  'guards: branching before the first commit is refused');
SELECT throws_like($$ SELECT grove.stash_pop() $$, '%no stash to pop%',
  'guards: popping an empty stash is refused');
SELECT throws_like($$ SELECT grove.checkout('nosuch') $$, '%unknown branch nosuch%',
  'guards: checking out a branch that is not there is refused');
SELECT throws_like($$ SELECT grove.rev('deadbeefdead') $$, '%no commit matching%',
  'guards: resolving a sha that matches nothing is refused');

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
SELECT grove.merge('feature');

CREATE TEMP TABLE m AS SELECT id FROM grove.merges ORDER BY id DESC LIMIT 1;
CREATE TEMP TABLE ck AS
SELECT c.k FROM grove.conflicts c WHERE c.merge_id = (SELECT id FROM m) LIMIT 1;

SELECT cmp_ok((SELECT count(*) FROM ck), '>', 0::bigint,
  'guards: there really is a conflict to aim the resolution guards at');

SELECT throws_like($$ SELECT grove.grant_level('postgres','bogus') $$,
  '%level must be read, write or admin%',
  'guards: an unknown access level is refused');
SELECT throws_like($$ SELECT grove.reset(encode(grove.resolve('main'),'hex'),'bogus') $$,
  '%reset takes soft or hard%',
  'guards: an unknown reset mode is refused, and it says why there is no third one');
SELECT throws_like($$ SELECT grove.resolve_all((SELECT id FROM m),'bogus') $$,
  '%resolve_all takes ours, theirs or base%',
  'guards: an unknown bulk resolution is refused');
SELECT throws_like(
  $$ SELECT grove.resolve_conflict((SELECT id FROM m),'t',(SELECT k FROM ck),'bogus') $$,
  '%unknown resolution bogus%',
  'guards: an unknown single resolution is refused');
SELECT throws_like(
  $$ SELECT grove.resolve_conflict((SELECT id FROM m),'t',(SELECT k FROM ck),'custom') $$,
  '%custom resolution needs a row image%',
  'guards: a custom resolution without the row it should write is refused');
SELECT throws_like(
  $$ SELECT grove.resolve_conflict((SELECT id FROM m),'t','ffff','ours') $$,
  '%no conflict on t.ffff%',
  'guards: resolving a conflict that is not there is refused');
SELECT throws_like($$ SELECT grove.revert(decode(repeat('ab',32),'hex')) $$, '%unknown commit%',
  'guards: reverting a commit that is not in the store is refused');
SELECT throws_like($$ SELECT grove.create_from_schema(grove.resolve('main'),'nosuchtable') $$,
  '%records no shape for%',
  'guards: creating a table the commit knows nothing about is refused');
SELECT throws_like($$ SELECT grove.tag('v1','nosuchspec') $$, '%cannot resolve nosuchspec%',
  'guards: tagging something that does not resolve is refused');

SELECT * FROM finish();
ROLLBACK;
