BEGIN;
SELECT plan(7);

CREATE TABLE t (id int PRIMARY KEY, v text);
CREATE TABLE audit (n bigserial PRIMARY KEY, what text);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'v'||g FROM generate_series(1,20) g;
SELECT grove.commit('base','alice');

CREATE FUNCTION note() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN INSERT INTO audit(what) VALUES (TG_OP); RETURN COALESCE(NEW, OLD); END $f$;
CREATE TRIGGER app_note AFTER INSERT OR UPDATE OR DELETE ON t
FOR EACH ROW EXECUTE FUNCTION note();

CREATE TEMP TABLE c AS SELECT count(*) AS n FROM audit;
UPDATE t SET v = 'by hand' WHERE id = 2;
SELECT cmp_ok((SELECT count(*) FROM audit) - (SELECT n FROM c), '>', 0::bigint,
  'replay triggers: an ordinary edit does fire the table trigger, so zero below means something');
SELECT grove.commit('a hand edit','alice');

SELECT grove.branch('side');
SELECT grove.checkout('side');
UPDATE t SET v = 'from side' WHERE id = 1;
INSERT INTO t VALUES (99, 'new on side');
SELECT grove.commit('side edits','bob');
SELECT grove.checkout('main');

TRUNCATE c; INSERT INTO c SELECT count(*) FROM audit;
SELECT grove.checkout('side', true);
SELECT is((SELECT count(*) FROM audit) - (SELECT n FROM c), 0::bigint,
  'replay triggers: checking out does not fire them');

SELECT grove.checkout('main', true);
UPDATE t SET v = 'on main' WHERE id = 3;
SELECT grove.commit('main edit','alice');

TRUNCATE c; INSERT INTO c SELECT count(*) FROM audit;
SELECT grove.merge('side');
SELECT is((SELECT count(*) FROM audit) - (SELECT n FROM c), 0::bigint,
  'replay triggers: a three way merge does not fire them while it applies its plan');

SELECT grove.branch('ff');
SELECT grove.checkout('ff');
UPDATE t SET v = 'ahead' WHERE id = 4;
SELECT grove.commit('ahead of main','bob');
SELECT grove.checkout('main');

TRUNCATE c; INSERT INTO c SELECT count(*) FROM audit;
SELECT grove.merge('ff');
SELECT is((SELECT count(*) FROM audit) - (SELECT n FROM c), 0::bigint,
  'replay triggers: nor does a fast forward merge, which takes a different path');

SELECT grove.branch('pick');
SELECT grove.checkout('pick');
UPDATE t SET v = 'to pick' WHERE id = 5;
CREATE TEMP TABLE picked AS SELECT grove.commit('worth picking','carol') AS sha;
SELECT grove.checkout('main');

TRUNCATE c; INSERT INTO c SELECT count(*) FROM audit;
SELECT grove.cherry_pick((SELECT sha FROM picked));
SELECT is((SELECT count(*) FROM audit) - (SELECT n FROM c), 0::bigint,
  'replay triggers: nor does cherry picking');

TRUNCATE c; INSERT INTO c SELECT count(*) FROM audit;
SELECT grove.revert(grove.rev('HEAD'));
SELECT is((SELECT count(*) FROM audit) - (SELECT n FROM c), 0::bigint,
  'replay triggers: nor does reverting');

CREATE TABLE parent_t (id int PRIMARY KEY);
CREATE TABLE child_t (id int PRIMARY KEY, parent_id int REFERENCES parent_t(id));
INSERT INTO parent_t VALUES (1);
INSERT INTO child_t VALUES (1, 1);
SELECT throws_ok($$ DELETE FROM parent_t WHERE id = 1 $$, NULL,
  'replay triggers: foreign keys are still enforced, suppressing user triggers did not switch them off');

SELECT * FROM finish();
ROLLBACK;
