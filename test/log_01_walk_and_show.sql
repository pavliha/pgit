BEGIN;
SELECT plan(10);

CREATE TABLE t1 (id int PRIMARY KEY, name text, hits int);
CREATE TABLE t2 (id int PRIMARY KEY, label text);
SELECT pgit.track('t1');
SELECT pgit.track('t2');

INSERT INTO t1 SELECT g, 'row-' || g, 0 FROM generate_series(1, 20) g;
INSERT INTO t2 VALUES (1, 'a'), (2, 'b');
CREATE TEMP TABLE c1 AS SELECT pgit.commit('create both', 'pavlo') AS sha;

UPDATE t1 SET hits = 1 WHERE id = 1;
CREATE TEMP TABLE c2 AS SELECT pgit.commit('touch t1 hits', 'pavlo') AS sha;

UPDATE t2 SET label = 'changed' WHERE id = 1;
CREATE TEMP TABLE c3 AS SELECT pgit.commit('touch t2', 'pavlo') AS sha;

UPDATE t1 SET name = 'renamed' WHERE id = 2;
CREATE TEMP TABLE c4 AS SELECT pgit.commit('touch t1 name', 'pavlo') AS sha;

SELECT is((SELECT count(*) FROM pgit.log()), 4::bigint, 'AC-LOG-01: log walks the whole chain');

SELECT is(
  (SELECT sha FROM pgit.log() WHERE depth = 0), (SELECT sha FROM c4),
  'AC-LOG-01: depth zero is HEAD'
);

SELECT is(
  (SELECT sha FROM pgit.log() ORDER BY depth DESC LIMIT 1), (SELECT sha FROM c1),
  'AC-LOG-01: the deepest entry is the root commit'
);

SELECT is(
  (SELECT parent_sha FROM pgit.log() ORDER BY depth DESC LIMIT 1), NULL,
  'AC-LOG-01: the root commit has no parent'
);

SELECT is(
  (SELECT count(*) FROM pgit.log((SELECT sha FROM c2))), 2::bigint,
  'AC-LOG-01: log from an older commit walks only its ancestry'
);

SELECT is(
  (SELECT count(*) FROM pgit.show((SELECT sha FROM c4))),
  (SELECT count(*) FROM pgit.diff((SELECT sha FROM c3), (SELECT sha FROM c4))),
  'AC-SHOW-01: show reports the same number of rows as diff against the parent'
);

SELECT is(
  (SELECT count(*) FROM (
     SELECT tbl, k, op, before, after FROM pgit.show((SELECT sha FROM c4))
     EXCEPT ALL
     SELECT tbl, k, op, before, after FROM pgit.diff((SELECT sha FROM c3), (SELECT sha FROM c4))
   ) q),
  0::bigint, 'AC-SHOW-01: show equals diff against the parent, row for row'
);

SELECT is(
  (SELECT string_agg(message, ',' ORDER BY depth) FROM pgit.log(NULL, 't2')),
  'touch t2,create both', 'AC-LOG-02: a table pathspec returns only commits touching that table'
);

SELECT is(
  (SELECT string_agg(message, ',' ORDER BY depth) FROM pgit.log(NULL, 't1.name')),
  'touch t1 name,create both',
  'AC-LOG-02: a column pathspec skips the commit that changed only another column'
);

SELECT is(
  length(pgit.short_sha((SELECT sha FROM c1))), 7,
  'log: short_sha is seven characters, as git prints'
);

SELECT * FROM finish();
ROLLBACK;
