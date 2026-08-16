BEGIN;
SELECT plan(1);

CREATE TABLE ord_src (zebra text NOT NULL, alpha int PRIMARY KEY, middle text NOT NULL);
INSERT INTO ord_src VALUES ('z', 1, 'm');
SELECT grove.track('ord_src');
SELECT grove.commit('a table whose columns are not in alphabetical order');

SELECT is(
  (SELECT string_agg(e.value ->> 'name', ',' ORDER BY e.ordinality)
   FROM grove.schemas s, jsonb_array_elements(s.columns) WITH ORDINALITY e
   WHERE s.commit_sha = grove.resolve('main') AND s.tbl = 'ord_src'),
  'zebra,alpha,middle',
  'AC-CLONE-01: the recorded shape keeps the columns in table order, not alphabetical');

SELECT * FROM finish();
ROLLBACK;
