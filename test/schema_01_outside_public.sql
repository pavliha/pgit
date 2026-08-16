BEGIN;
SELECT plan(9);

CREATE TABLE t (id int PRIMARY KEY, v text);

SET search_path = pg_catalog;
SELECT grove.track('public.t');
INSERT INTO public.t SELECT g, 'v'||g FROM generate_series(1,50) g;
SELECT grove.commit('base','alice');
SELECT grove.branch('side');
RESET search_path;

SELECT is((SELECT string_agg(DISTINCT tbl, ',') FROM grove.trees), 'public.t',
  'search_path: the commit recorded the qualified name it saw at the time');
SELECT is((SELECT tbl::text FROM grove.tracked), 't',
  'search_path: and this session renders the very same table differently, which is the whole problem');
SELECT is((SELECT string_agg(DISTINCT tbl, ',') FROM grove.schemas), 'public.t',
  'search_path: the shape is recorded under the same name as the tree');

SELECT ok(NOT grove.is_dirty(),
  'search_path: the table matches its commit, whatever this session calls it');
SELECT throws_like($$ SELECT grove.commit('nothing changed','bob') $$, '%nothing to commit%',
  'search_path: and commit agrees there is nothing to record');

UPDATE t SET v = 'changed' WHERE id = 1;
SELECT ok(grove.commit('second','bob') IS NOT NULL,
  'search_path: a real change still commits');
SELECT is((SELECT count(DISTINCT tbl) FROM grove.trees), 1::bigint,
  'search_path: under one name throughout, not a new one per session');

SELECT ok(grove.checkout('side', true) >= 0,
  'search_path: an earlier branch checks out');
SELECT is((SELECT v FROM t WHERE id = 1), 'v1',
  'search_path: and puts the old value back');

SELECT * FROM finish();
ROLLBACK;
