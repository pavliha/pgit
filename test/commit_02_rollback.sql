BEGIN;
SELECT plan(3);

CREATE TABLE t (id int PRIMARY KEY, name text);
SELECT pgit.track('t');
INSERT INTO t VALUES (1, 'kept');

SELECT pgit.commit('kept commit', 'pavlo');

CREATE TEMP TABLE baseline AS
  SELECT (SELECT count(*) FROM pgit.commits) AS commits,
         (SELECT count(*) FROM pgit.nodes) AS nodes,
         pgit.resolve('main') AS head;

SAVEPOINT sp;
INSERT INTO t VALUES (2, 'discarded');
SELECT pgit.commit('discarded commit', 'pavlo');
ROLLBACK TO SAVEPOINT sp;

SELECT is(
  (SELECT count(*) FROM pgit.commits), (SELECT commits FROM baseline),
  'AC-COMMIT-02: a rolled back transaction leaves no commit'
);

SELECT is(
  (SELECT count(*) FROM pgit.nodes), (SELECT nodes FROM baseline),
  'AC-COMMIT-02: a rolled back transaction leaves no tree nodes'
);

SELECT is(
  pgit.resolve('main'), (SELECT head FROM baseline),
  'AC-COMMIT-02: a rolled back transaction leaves the ref where it was'
);

SELECT * FROM finish();
ROLLBACK;
