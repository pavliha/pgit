BEGIN;
SELECT plan(9);

CREATE TABLE side_effects (id serial PRIMARY KEY, op text);
CREATE TABLE t (id int PRIMARY KEY, name text, hits int);

CREATE FUNCTION note_it() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO side_effects (op) VALUES (TG_OP);
  RETURN NULL;
END $$;

CREATE TRIGGER user_side_effect AFTER INSERT OR UPDATE OR DELETE ON t
  FOR EACH ROW EXECUTE FUNCTION note_it();

SELECT pgit.track('t');
INSERT INTO t SELECT g, 'row-' || g, 0 FROM generate_series(1, 50) g;
CREATE TEMP TABLE a AS SELECT pgit.commit('a', 'pavlo') AS sha;

UPDATE t SET name = 'changed' WHERE id = 5;
DELETE FROM t WHERE id = 6;
INSERT INTO t VALUES (500, 'new', 1);
CREATE TEMP TABLE b AS SELECT pgit.commit('b', 'pavlo') AS sha;

DELETE FROM side_effects;
CREATE TEMP TABLE journal_before AS SELECT count(*) AS n FROM pgit.changes;

SELECT pgit.revert((SELECT sha FROM b));

SELECT is((SELECT name FROM t WHERE id = 5), 'row-5', 'revert restores an updated value');
SELECT is((SELECT count(*) FROM t WHERE id = 6), 1::bigint, 'revert restores a deleted row');
SELECT is((SELECT count(*) FROM t WHERE id = 500), 0::bigint, 'revert removes an inserted row');

SELECT is(
  (SELECT count(*) FROM side_effects), 0::bigint,
  'AC-REPLAY-01: no user trigger fires during replay'
);

SELECT ok(
  (SELECT count(*) FROM pgit.changes) > (SELECT n FROM journal_before),
  'pgit journal is ENABLE ALWAYS, so it still records what replay actually wrote'
);

SELECT is(
  pgit.tree_root('t'),
  (SELECT root_hash FROM pgit.trees WHERE commit_sha = (SELECT sha FROM a) AND tbl = 't'),
  'AC-REPLAY-03: reverting a commit restores the parent content exactly, by root hash'
);

CREATE TEMP TABLE c AS SELECT pgit.resolve('main') AS sha;
SELECT pgit.revert((SELECT sha FROM c));

SELECT is(
  pgit.tree_root('t'),
  (SELECT root_hash FROM pgit.trees WHERE commit_sha = (SELECT sha FROM b) AND tbl = 't'),
  'AC-REPLAY-03: revert of a revert restores the original content'
);

UPDATE t SET name = 'meddled with' WHERE id = 5;

SELECT throws_ok(
  format($$ SELECT pgit.revert(%L::bytea) $$, (SELECT sha FROM b)),
  NULL, NULL,
  'AC-REPLAY-04: revert refuses when a row it would touch has changed since'
);

CREATE TEMP TABLE journal_mark AS SELECT count(*) AS n FROM pgit.changes;
CREATE TEMP TABLE reads AS
  SELECT count(*) AS c FROM pgit.diff((SELECT sha FROM a), (SELECT sha FROM b));

SELECT is(
  (SELECT count(*) FROM pgit.changes), (SELECT n FROM journal_mark),
  'AC-REPLAY-02: reading a diff adds no journal rows, so history cannot grow by being re-read'
);

SELECT * FROM finish();
ROLLBACK;
