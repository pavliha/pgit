BEGIN;
SELECT plan(7);

CREATE TABLE items (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name text);
SELECT grove.track('items');
INSERT INTO items (name) SELECT 'item '||g FROM generate_series(1,200) g;
SELECT grove.commit('base','alice');
SELECT grove.branch('side');

CREATE TEMP TABLE s AS SELECT pg_get_serial_sequence('items','id') AS seq;
CREATE OR REPLACE FUNCTION pg_temp.seqval() RETURNS bigint LANGUAGE sql AS $$
  SELECT last_value FROM pg_sequences WHERE sequencename = split_part((SELECT seq FROM s), '.', 2)
$$;

SELECT isnt((SELECT seq FROM s), NULL,
  'sequences: the identity column really has a sequence behind it');

SELECT setval((SELECT seq FROM s), 1, true);
SELECT is(pg_temp.seqval(), 1::bigint,
  'sequences: put it behind the data, which is the state a clone leaves it in');

SELECT grove.checkout('side', true);

SELECT cmp_ok(pg_temp.seqval(), '>=', 200::bigint,
  'sequences: a replay brings it up to the rows that are actually there');

SELECT is(grove.write_tree('items'),
  (SELECT root_hash FROM grove.trees WHERE commit_sha = grove.resolve('side') AND tbl = 'items'),
  'sequences: and where the sequence sits is no part of the data, the tree is untouched');

INSERT INTO items (name) VALUES ('the next one');
SELECT is((SELECT max(id) FROM items), 201,
  'sequences: so the next insert does not collide with a restored row');

SELECT grove.commit('one more','bob');
SELECT setval((SELECT seq FROM s), 9999, true);
SELECT grove.checkout('main', true);

SELECT is(pg_temp.seqval(), 9999::bigint,
  'sequences: a replay never winds one backwards, ids already handed out stay spent');

SELECT is((SELECT count(*) FROM grove.fsck()), 0::bigint,
  'sequences: and the store is untouched by any of it');

SELECT * FROM finish();
ROLLBACK;
