BEGIN;
SELECT plan(11);

CREATE TABLE victim (id int PRIMARY KEY, secret text);
INSERT INTO victim VALUES (1, 'classified');

CREATE TEMP TABLE poisoned AS
SELECT grove.hash('poisoned'::text) AS sha;

INSERT INTO grove.commits (sha, parent_sha, author, message, at)
SELECT sha, NULL, 'attacker', 'poisoned bundle', now() FROM poisoned
ON CONFLICT DO NOTHING;

INSERT INTO grove.schemas (commit_sha, tbl, fingerprint, columns, pk_cols)
SELECT sha, 'loot', grove.hash('x'::text),
       '[{"name":"id","type":"int, PRIMARY KEY (id)); DROP TABLE victim; --"}]'::jsonb,
       ARRAY['id']
FROM poisoned;

SELECT throws_ok(
  $$SELECT grove.create_from_schema((SELECT sha FROM poisoned), 'loot')$$,
  NULL,
  'security: a bundle whose column type carries a second statement is refused');

SELECT ok(
  to_regclass('victim') IS NOT NULL,
  'security: and the table that statement tried to drop is still there');

SELECT ok(
  to_regclass('loot') IS NULL,
  'security: nothing was created from the poisoned shape');

SELECT is(
  (SELECT count(*) FROM victim)::int, 1,
  'security: the rows it protects are untouched');

SELECT is(
  grove.checked_type('character varying(50)'), 'character varying(50)',
  'security: a real type passes through with its modifier intact');

SELECT is(
  grove.checked_type('numeric(10,2)'), 'numeric(10,2)',
  'security: including a two argument modifier');

SELECT is(
  grove.checked_type('int[]'), 'int[]',
  'security: and an array type');

SELECT throws_ok(
  $$SELECT grove.checked_type('notatype')$$,
  NULL,
  'security: a name that parses but is not a type is refused too');

CREATE TABLE donor (id int PRIMARY KEY, label text, amount numeric(10,2), tags text[]);
SELECT grove.track('donor');
INSERT INTO donor VALUES (1, 'x', 1.25, ARRAY['a']);
CREATE TEMP TABLE donor_c AS SELECT grove.commit('donor base', 'main') AS sha;
SELECT grove.untrack('donor');
DROP TABLE donor;

SELECT lives_ok(
  $$SELECT grove.create_from_schema((SELECT sha FROM donor_c), 'donor')$$,
  'security: a shape recorded from a real table rebuilds the table it describes');

SELECT is(
  (SELECT count(*)::int FROM information_schema.columns WHERE table_name = 'donor'), 4,
  'security: with every column');

SELECT is(
  (SELECT data_type || ':' || numeric_precision || ',' || numeric_scale
   FROM information_schema.columns WHERE table_name = 'donor' AND column_name = 'amount'),
  'numeric:10,2',
  'security: and the type modifiers survive the round trip');

SELECT * FROM finish();
ROLLBACK;
