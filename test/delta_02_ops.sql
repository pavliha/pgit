BEGIN;
SELECT plan(18);

CREATE TEMP TABLE fix (label text PRIMARY KEY, base jsonb, target jsonb);
INSERT INTO fix VALUES
  ('one field',
   '[{"k":"a","h":"01","v":{"id":1,"hits":5}}, {"k":"b","h":"02","v":{"id":2,"hits":5}}, {"k":"c","h":"03","v":{"id":3,"hits":5}}]',
   '[{"k":"a","h":"01","v":{"id":1,"hits":5}}, {"k":"b","h":"09","v":{"id":2,"hits":6}}, {"k":"c","h":"03","v":{"id":3,"hits":5}}]'),
  ('two far apart',
   '[{"k":"a","h":"01","v":{"id":1,"hits":5}}, {"k":"b","h":"02","v":{"id":2,"hits":5}}, {"k":"c","h":"03","v":{"id":3,"hits":5}}]',
   '[{"k":"a","h":"07","v":{"id":1,"hits":8}}, {"k":"b","h":"02","v":{"id":2,"hits":5}}, {"k":"c","h":"08","v":{"id":3,"hits":9}}]'),
  ('two far apart wide',
   (SELECT jsonb_agg(jsonb_build_object('k', chr(96+g), 'h', lpad(g::text,2,'0'),
                                        'v', jsonb_build_object('id', g, 'hits', 5)) ORDER BY g)
    FROM generate_series(1,8) g),
   (SELECT jsonb_agg(jsonb_build_object('k', chr(96+g), 'h', CASE WHEN g IN (1,8) THEN '9' || g ELSE lpad(g::text,2,'0') END,
                                        'v', jsonb_build_object('id', g, 'hits', CASE WHEN g IN (1,8) THEN 7 ELSE 5 END)) ORDER BY g)
    FROM generate_series(1,8) g)),
  ('inserted key',
   '[{"k":"a","h":"01","v":{"id":1}}, {"k":"c","h":"03","v":{"id":3}}]',
   '[{"k":"a","h":"01","v":{"id":1}}, {"k":"b","h":"02","v":{"id":2}}, {"k":"c","h":"03","v":{"id":3}}]'),
  ('deleted key',
   '[{"k":"a","h":"01","v":{"id":1}}, {"k":"b","h":"02","v":{"id":2}}, {"k":"c","h":"03","v":{"id":3}}]',
   '[{"k":"a","h":"01","v":{"id":1}}, {"k":"c","h":"03","v":{"id":3}}]'),
  ('single entry',
   '[{"k":"a","h":"01","v":{"id":1,"hits":5}}]',
   '[{"k":"a","h":"09","v":{"id":1,"hits":6}}]'),
  ('nothing changed',
   '[{"k":"a","h":"01","v":{"id":1}}, {"k":"b","h":"02","v":{"id":2}}]',
   '[{"k":"a","h":"01","v":{"id":1}}, {"k":"b","h":"02","v":{"id":2}}]'),
  ('everything changed',
   '[{"k":"a","h":"01","v":{"id":1}}, {"k":"b","h":"02","v":{"id":2}}]',
   '[{"k":"x","h":"91","v":{"id":91}}, {"k":"y","h":"92","v":{"id":92}}]'),
  ('empty base',
   '[]',
   '[{"k":"a","h":"01","v":{"id":1}}]'),
  ('quotes and backslashes',
   '[{"k":"a","h":"01","v":{"s":"he said \"hi\" \\ ok"}}, {"k":"b","h":"02","v":{"s":"x"}}]',
   '[{"k":"a","h":"01","v":{"s":"he said \"hi\" \\ ok"}}, {"k":"b","h":"02","v":{"s":"y"}}]'),
  ('unicode',
   '[{"k":"a","h":"01","v":{"s":"ქართული"}}, {"k":"b","h":"02","v":{"s":"日本"}}]',
   '[{"k":"a","h":"01","v":{"s":"ქართული"}}, {"k":"b","h":"02","v":{"s":"日本語"}}]');

SELECT is(
  (SELECT count(*) FROM fix
   WHERE grove.apply_delta(base, grove.make_delta(base, target)) IS DISTINCT FROM target),
  0::bigint,
  'delta ops: every fixture round trips to exactly its target');

SELECT is(
  (SELECT count(*) FROM fix
   WHERE grove.apply_delta_bin(convert_to(base::text, 'UTF8'), grove.make_delta(base, target))
         IS DISTINCT FROM convert_to(target::text, 'UTF8')),
  0::bigint,
  'delta ops: the spliced bytes are byte identical, not merely jsonb equal');

CREATE TEMP VIEW payload AS
SELECT f.label,
       COALESCE(sum(length(o ->> 'i')) FILTER (WHERE o ? 'i'), 0)::int AS inserted,
       length(f.target::text) AS node_chars,
       length(f.target::text)
         - grove.common_prefix(f.base::text, f.target::text)
         - grove.common_suffix(f.base::text, f.target::text,
             least(length(f.base::text), length(f.target::text))
             - grove.common_prefix(f.base::text, f.target::text)) AS one_splice
FROM fix f CROSS JOIN LATERAL jsonb_array_elements(grove.make_delta(f.base, f.target)) o
GROUP BY f.label, f.base, f.target;

SELECT cmp_ok(
  (SELECT inserted FROM payload WHERE label = 'one field'), '<=',
  (SELECT one_splice FROM payload WHERE label = 'one field'),
  'delta ops: one changed row inserts no more than a single splice would');

SELECT cmp_ok(
  (SELECT inserted FROM payload WHERE label = 'two far apart wide'), '<',
  (SELECT one_splice / 2 FROM payload WHERE label = 'two far apart wide'),
  'delta ops: two changes at opposite ends insert under half what one splice must, which is the whole point');

SELECT cmp_ok(
  (SELECT one_splice FROM payload WHERE label = 'two far apart wide'), '>',
  (SELECT node_chars * 3 / 4 FROM payload WHERE label = 'two far apart wide'),
  'delta ops: and one splice really would have had to cover most of the node, so that is not vacuous');

SELECT cmp_ok(
  (SELECT jsonb_array_length(grove.make_delta(base, target)) FROM fix WHERE label = 'two far apart wide'),
  '>', 3,
  'delta ops: that case really did emit more than three ops, so the test is not vacuous');

SELECT is(
  (SELECT jsonb_array_length(grove.make_delta(base, target)) FROM fix WHERE label = 'nothing changed'),
  1,
  'delta ops: an unchanged node collapses to a single copy of the whole base');

SELECT is(
  (SELECT grove.make_delta(base, target) -> 0 -> 'c' FROM fix WHERE label = 'nothing changed'),
  jsonb_build_array(1, (SELECT length(base::text) FROM fix WHERE label = 'nothing changed')),
  'delta ops: and that copy spans the base exactly');

SELECT is(
  (SELECT count(*) FROM fix
   WHERE jsonb_typeof(grove.make_delta(base, target)) <> 'array'),
  0::bigint,
  'delta ops: the format is always an op array, never the old p/s/m object');

SELECT cmp_ok(
  (SELECT pg_column_size(grove.make_delta(base, target)) FROM fix WHERE label = 'two far apart'),
  '>',
  (SELECT pg_column_size(target) FROM fix WHERE label = 'two far apart'),
  'delta ops: on a node this small the op envelope costs more than the node, which repack must notice');

CREATE TABLE t (id int PRIMARY KEY, name text, body text, hits int);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'row-' || g, repeat('payload ', 20) || g, 0 FROM generate_series(1, 5000) g;
CREATE TEMP TABLE a AS SELECT grove.commit('base', 'b') AS sha;

DO $$ DECLARE i int; BEGIN
  FOR i IN 1..120 LOOP
    UPDATE t SET hits = i WHERE id = 2000 + i;
    UPDATE t SET hits = i WHERE id = 2000 + i + 30;
    PERFORM grove.commit('c' || i, 'b');
  END LOOP;
END $$;

ANALYZE grove.nodes;

CREATE TEMP TABLE qplan (p text);
DO $$
DECLARE r record; fk text;
BEGIN
  SELECT n.keys[1] INTO fk FROM grove.nodes n WHERE n.entries IS NOT NULL LIMIT 1;
  FOR r IN EXECUTE format(
    'EXPLAIN SELECT n.hash FROM grove.nodes n WHERE n.level = 0 AND n.keys[1] = %L '
    'AND n.entries IS NOT NULL ORDER BY n.seq DESC', fk)
  LOOP
    INSERT INTO qplan VALUES (r."QUERY PLAN");
  END LOOP;
END $$;

SELECT cmp_ok((SELECT count(*) FROM grove.nodes)::int, '>', 500,
  'delta ops: the fixture is big enough that a sequential scan is not the planner''s obvious choice');

SELECT ok(
  EXISTS (SELECT 1 FROM qplan WHERE p LIKE '%nodes_group_idx%'),
  'delta ops: the group lookup repack drives off resolves through nodes_group_idx, not a seq scan');

CREATE TEMP TABLE before_entries AS SELECT hash, grove.entries_of(hash) AS e FROM grove.nodes;
CREATE TEMP TABLE before_diff AS SELECT * FROM grove.diff((SELECT sha FROM a), grove.resolve('main'));
CREATE TEMP TABLE before_size AS
  SELECT sum(pg_column_size(entries) + COALESCE(pg_column_size(delta), 0) + COALESCE(pg_column_size(hashes), 0) + COALESCE(pg_column_size(keys), 0))::bigint AS sz FROM grove.nodes;

CREATE TEMP TABLE packed AS SELECT grove.repack(50) AS n;

SELECT cmp_ok((SELECT n FROM packed), '>', 100, 'delta ops: depth 50 deltified over a hundred nodes');

SELECT is(
  (SELECT count(*) FROM before_entries b WHERE b.e IS DISTINCT FROM grove.entries_of(b.hash)),
  0::bigint,
  'delta ops: every node still resolves byte identically after a depth 50 repack');

SELECT is(
  (SELECT count(*) FROM (
     SELECT * FROM grove.diff((SELECT sha FROM a), grove.resolve('main'))
     EXCEPT ALL SELECT * FROM before_diff) q), 0::bigint,
  'delta ops: diff across the whole range returns the same rows');

SELECT is(
  grove.write_tree('t'),
  (SELECT root_hash FROM grove.trees WHERE commit_sha = grove.resolve('main') AND tbl = 't'),
  'delta ops: a fresh full rebuild still matches the packed tree');

SELECT cmp_ok(
  (SELECT sum(pg_column_size(entries) + COALESCE(pg_column_size(delta), 0) + COALESCE(pg_column_size(hashes), 0) + COALESCE(pg_column_size(keys), 0))::bigint FROM grove.nodes),
  '<', (SELECT sz / 2 FROM before_size),
  'delta ops: two changed rows per commit pack to under half the stored bytes');

SELECT is((SELECT grove.unpack()), (SELECT n FROM packed),
  'delta ops: unpack materialises exactly the deltified nodes again');

SELECT * FROM finish();
ROLLBACK;
