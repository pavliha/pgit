BEGIN;
SELECT plan(7);

CREATE TABLE hostile (
  id      int PRIMARY KEY,
  "value" text,
  "h"     text,
  "v"     int,
  "select" text,
  "grove entry" text
);
SELECT grove.track('hostile');
INSERT INTO hostile SELECT g, 'val-'||g, 'h-'||g, g, 'sel-'||g, 'ent-'||g
FROM generate_series(1,120) g;
SELECT grove.commit('hostile columns','alice');

SELECT is((SELECT count(*) FROM grove.fsck()), 0::bigint,
  'hostile columns: fsck runs and finds nothing, columns named value and h do not collide');

SELECT cmp_ok(jsonb_array_length(grove.bundle(ARRAY['main']) -> 'commits'), '>', 0,
  'hostile columns: the table bundles');

SELECT lives_ok($$ SELECT grove.verify_images(
  (SELECT jsonb_agg(jsonb_build_object('h', l.rh, 'v', l.v))
   FROM grove.leaves((SELECT root_hash FROM grove.trees WHERE tbl = 'hostile')) l),
  (SELECT columns FROM grove.schemas WHERE tbl = 'hostile')) $$,
  'hostile columns: image verification builds a query that parses');

SELECT is(grove.verify_images(
  (SELECT jsonb_agg(jsonb_build_object('h', l.rh, 'v', l.v))
   FROM grove.leaves((SELECT root_hash FROM grove.trees WHERE tbl = 'hostile')) l),
  (SELECT columns FROM grove.schemas WHERE tbl = 'hostile')), 0,
  'hostile columns: every honest row image verifies');

UPDATE grove.nodes SET entries = jsonb_set(entries, '{0,value}', '"POISONED"')
WHERE level = 0 AND entries IS NOT NULL AND jsonb_array_length(entries) > 0;

SELECT cmp_ok((SELECT count(*) FROM grove.nodes WHERE entries::text LIKE '%POISONED%'), '>', 0::bigint,
  'hostile columns: the poisoned image really is in the store');
SELECT cmp_ok((SELECT count(*) FROM grove.fsck() WHERE problem = 'row images do not hash to their rows'),
  '>', 0::bigint,
  'hostile columns: a poisoned image is still caught when a column is called value');

CREATE TABLE collides (id int PRIMARY KEY, "grove row" text);
SELECT throws_like($$ SELECT grove.track('collides') $$, '%collide with the aliases%',
  'hostile columns: a column named after one of grove''s own aliases is refused at track time');

SELECT * FROM finish();
ROLLBACK;
