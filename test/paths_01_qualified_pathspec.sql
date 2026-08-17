BEGIN;
SELECT plan(11);

CREATE SCHEMA app;
CREATE TABLE app.t (id int PRIMARY KEY, a text, b text);
SELECT grove.track('app.t');
INSERT INTO app.t VALUES (1, 'v0', 'x0'), (2, 'w0', 'y0');
SELECT grove.commit('base', 'pavlo');

SELECT is((SELECT tbl FROM grove.trees LIMIT 1), 'app.t',
  'AC-PATH: the fixture really records a schema qualified name, so the dot is load bearing');

SELECT is((SELECT s.tbl FROM grove.parse_pathspec('app.t', ARRAY['app.t']) s), 'app.t',
  'AC-PATH: a qualified pathspec names the table, where splitting on the first dot used to yield the schema');

SELECT is((SELECT s.col FROM grove.parse_pathspec('app.t', ARRAY['app.t']) s), NULL,
  'AC-PATH: and it does not mistake the table part for a column');

SELECT is((SELECT s.col FROM grove.parse_pathspec('app.t.a', ARRAY['app.t']) s), 'a',
  'AC-PATH: a column after a qualified table is still a column');

SELECT is((SELECT s.row_k FROM grove.parse_pathspec('app.t:1', ARRAY['app.t']) s), '1',
  'AC-PATH: and so is a row key after one');

SELECT is((SELECT s.tbl || '/' || s.col FROM grove.parse_pathspec('t.a', ARRAY['t']) s), 't/a',
  'AC-PATH: an unqualified table with a column still parses the old way');

SELECT is((SELECT s.tbl FROM grove.parse_pathspec('nosuchtable', ARRAY['app.t']) s), 'nosuchtable',
  'AC-PATH: a pathspec matching no candidate keeps its own text, so callers can reject it');

UPDATE app.t SET a = 'v1' WHERE id = 1;
SELECT set_config('probe.base', encode(grove.resolve('main'), 'hex'), false);
SELECT grove.commit('changed', 'pavlo');

SELECT cmp_ok((SELECT count(*) FROM grove.diff(decode(current_setting('probe.base'), 'hex'),
                                              grove.resolve('main'), 'app.t')), '=', 1::bigint,
  'AC-PATH: diff scoped to a qualified table finds the change');

SELECT is((SELECT grove.restore(current_setting('probe.base'), 'app.t')), 1,
  'AC-PATH: restore scoped to a qualified table writes the row, where it used to report zero and do nothing');

SELECT is((SELECT a FROM app.t WHERE id = 1), 'v0',
  'AC-PATH: and the value really went back, so the count was not the only thing that changed');

SELECT throws_like(
  $$ SELECT grove.restore(current_setting('probe.base'), 'nosuchtable') $$,
  '%not a tracked table%',
  'AC-PATH: restore refuses a pathspec naming no tracked table instead of quietly restoring nothing');

SELECT * FROM finish();
ROLLBACK;
