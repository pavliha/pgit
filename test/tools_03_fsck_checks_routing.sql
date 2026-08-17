BEGIN;
SELECT plan(8);

CREATE TABLE t (id int PRIMARY KEY, a text);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'v' || g FROM generate_series(1, 400) g;
SELECT grove.commit('base', 'pavlo');

CREATE TEMP TABLE victim AS
  SELECT hash FROM grove.nodes WHERE level = 1 AND array_length(keys, 1) > 2 LIMIT 1;

SELECT cmp_ok((SELECT count(*) FROM victim), '=', 1::bigint,
  'AC-TOOLS: the fixture really built an interior node with several children to corrupt');

SELECT is((SELECT count(*) FROM grove.fsck()), 0::bigint,
  'AC-TOOLS: the store starts clean, so anything below is the corruption talking');

CREATE TEMP TABLE probe AS
  SELECT unnest(keys) AS k FROM grove.nodes WHERE level = 0 LIMIT 20;

CREATE FUNCTION resolving() RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM probe p
  WHERE (SELECT lo.rh FROM grove.lookup((SELECT root_hash FROM grove.trees LIMIT 1), p.k) lo) IS NOT NULL;
$$;

SELECT cmp_ok(resolving(), '>', 0::bigint,
  'AC-TOOLS: and every probed key resolves through the tree while it is intact');

CREATE FUNCTION flip() RETURNS void LANGUAGE sql AS $$
  UPDATE grove.nodes
  SET keys = (SELECT array_agg(k ORDER BY o DESC) FROM unnest(keys) WITH ORDINALITY AS u(k, o))
  WHERE hash = (SELECT hash FROM victim);
$$;

SELECT flip();

SELECT is(resolving(), 0::bigint,
  'AC-TOOLS: reversing one interior key vector breaks every lookup, so the vector is load bearing');

SELECT is((SELECT count(*) FROM grove.fsck()
           WHERE problem = 'node key does not match the child it points at'), 3::bigint,
  'AC-TOOLS: fsck names it, where it used to report the whole store clean');

SELECT flip();

SELECT is((SELECT count(*) FROM grove.fsck()), 0::bigint,
  'AC-TOOLS: putting the vector back clears it, so fsck is reading the store not remembering');

UPDATE grove.nodes SET level = 7 WHERE hash = (SELECT hash FROM victim);

SELECT cmp_ok((SELECT count(*) FROM grove.fsck()
               WHERE problem = 'node level does not match its children'), '>', 0::bigint,
  'AC-TOOLS: a level that disagrees with its children is caught too, and was also invisible');

UPDATE grove.nodes SET level = 1 WHERE hash = (SELECT hash FROM victim);

SELECT is((SELECT count(*) FROM grove.fsck()), 0::bigint,
  'AC-TOOLS: and restoring the level clears that too');

SELECT * FROM finish();
ROLLBACK;
