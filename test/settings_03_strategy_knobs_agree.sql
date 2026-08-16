BEGIN;
SELECT plan(5);

CREATE TABLE t (id int PRIMARY KEY, v text, n int);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'v'||g, 0 FROM generate_series(1,800) g;
SELECT grove.commit('base','alice');

UPDATE t SET n = 1 WHERE id % 7 = 0;
DELETE FROM t WHERE id % 97 = 0;
INSERT INTO t SELECT g, 'new'||g, 5 FROM generate_series(801,860) g;

CREATE TEMP TABLE roots AS
SELECT grove.write_tree('t') AS full_root,
       (SELECT root_hash FROM grove.trees
        WHERE commit_sha = grove.resolve('main') AND tbl = 't') AS base_root;

SELECT isnt((SELECT full_root FROM roots), (SELECT base_root FROM roots),
  'strategy knobs: the edits really moved the tree, so the comparisons below are not vacuous');

CREATE TEMP TABLE ran (mik text, smc text, rwf text, root bytea);

DO $$
DECLARE
  mik text; smc text; rwf text; b bytea;
BEGIN
  SELECT base_root INTO b FROM roots;

  FOREACH mik IN ARRAY ARRAY['0','1','10000'] LOOP
    FOREACH smc IN ARRAY ARRAY['0','8','100000'] LOOP
      FOREACH rwf IN ARRAY ARRAY['0','0.75','1'] LOOP
        UPDATE grove.meta SET value = mik WHERE key = 'max_incremental_keys';
        UPDATE grove.meta SET value = smc WHERE key = 'splice_max_changes_per_chunk';
        UPDATE grove.meta SET value = rwf WHERE key = 'rebuild_when_hit_fraction';
        INSERT INTO ran VALUES (mik, smc, rwf, grove.write_tree_incremental('t', b));
      END LOOP;
    END LOOP;
  END LOOP;
END $$;

SELECT is((SELECT count(*) FROM ran), 27::bigint,
  'strategy knobs: all 27 combinations ran');

SELECT is((SELECT count(*) FROM ran WHERE root IS DISTINCT FROM (SELECT full_root FROM roots)),
  0::bigint,
  'strategy knobs: every combination reaches the same tree as a full rebuild');

UPDATE grove.meta SET value = '-1' WHERE key = 'max_incremental_keys';
UPDATE grove.meta SET value = '-5' WHERE key = 'splice_max_changes_per_chunk';
UPDATE grove.meta SET value = '-0.5' WHERE key = 'rebuild_when_hit_fraction';

SELECT is(grove.write_tree_incremental('t', (SELECT base_root FROM roots)),
  (SELECT full_root FROM roots),
  'strategy knobs: a nonsensical negative value still reaches the right tree, it only picks a path');

UPDATE grove.meta SET value = '10000' WHERE key = 'max_incremental_keys';
UPDATE grove.meta SET value = '8' WHERE key = 'splice_max_changes_per_chunk';
UPDATE grove.meta SET value = '0.75' WHERE key = 'rebuild_when_hit_fraction';

UPDATE grove.meta SET value = '0' WHERE key = 'max_tree_depth';
SELECT throws_like($$ SELECT grove.write_tree('t') $$, '%tree depth exceeded%',
  'strategy knobs: a knob that cannot be honoured stops the build instead of writing a wrong tree');

SELECT * FROM finish();
ROLLBACK;
