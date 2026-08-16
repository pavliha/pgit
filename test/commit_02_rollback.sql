BEGIN;
SELECT plan(3);

CREATE TABLE t (id int PRIMARY KEY, name text);
SELECT grove.track('t');
INSERT INTO t VALUES (1, 'kept');

SELECT grove.commit('kept commit', 'pavlo');

CREATE TEMP TABLE baseline AS
  SELECT (SELECT count(*) FROM grove.commits) AS commits,
         (SELECT count(*) FROM grove.nodes) AS nodes,
         grove.resolve('main') AS head;

SAVEPOINT sp;
INSERT INTO t VALUES (2, 'discarded');
SELECT grove.commit('discarded commit', 'pavlo');
ROLLBACK TO SAVEPOINT sp;

SELECT is(
  (SELECT count(*) FROM grove.commits), (SELECT commits FROM baseline),
  'AC-COMMIT-02: a rolled back transaction leaves no commit'
);

SELECT is(
  (SELECT count(*) FROM grove.nodes), (SELECT nodes FROM baseline),
  'AC-COMMIT-02: a rolled back transaction leaves no tree nodes'
);

SELECT is(
  grove.resolve('main'), (SELECT head FROM baseline),
  'AC-COMMIT-02: a rolled back transaction leaves the ref where it was'
);

SELECT * FROM finish();
ROLLBACK;
