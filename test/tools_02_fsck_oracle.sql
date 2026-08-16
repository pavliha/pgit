BEGIN;
SELECT plan(12);

CREATE TABLE t (id int PRIMARY KEY, name text, price int);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'row-'||g, g*10 FROM generate_series(1,300) g;
SELECT grove.commit('first','alice');
UPDATE t SET price = price + 1 WHERE id <= 20;
SELECT grove.commit('second','bob');

SELECT is((SELECT count(*) FROM grove.fsck()), 0::bigint,
  'fsck oracle: a healthy repository reports nothing');

SAVEPOINT s1;
UPDATE grove.nodes SET entries = jsonb_set(entries, '{0,name}', '"POISONED"')
WHERE level = 0 AND entries IS NOT NULL AND jsonb_array_length(entries) > 0;
SELECT cmp_ok((SELECT count(*) FROM grove.nodes WHERE entries::text LIKE '%POISONED%'), '>', 0::bigint,
  'fsck oracle: the poisoned image really is in the store');
SELECT cmp_ok((SELECT count(*) FROM grove.fsck() WHERE problem = 'row images do not hash to their rows'),
  '>', 0::bigint,
  'fsck oracle: a row image edited in place is caught, though every node still hashes');
ROLLBACK TO s1;

SAVEPOINT s2;
UPDATE grove.commits SET author = 'trusted-reviewer', message = 'Approved by security team';
SELECT is((SELECT count(*) FROM grove.commits WHERE author = 'trusted-reviewer'), 2::bigint,
  'fsck oracle: the rewritten author really is stored');
SELECT is((SELECT count(*) FROM grove.fsck() WHERE problem = 'commit does not hash to its own content'),
  2::bigint,
  'fsck oracle: rewriting who committed and why is caught');
ROLLBACK TO s2;

SAVEPOINT s3;
UPDATE grove.commits SET at = at - interval '5 years';
SELECT is((SELECT count(*) FROM grove.fsck() WHERE problem = 'commit does not hash to its own content'),
  2::bigint,
  'fsck oracle: backdating a commit is caught, the time is part of the sha');
ROLLBACK TO s3;

SAVEPOINT s4;
UPDATE grove.schemas SET fingerprint = decode(repeat('ab',32),'hex');
SELECT cmp_ok((SELECT count(*) FROM grove.schemas WHERE fingerprint = decode(repeat('ab',32),'hex')),
  '>', 0::bigint, 'fsck oracle: the forged fingerprint really is stored');
SELECT cmp_ok((SELECT count(*) FROM grove.fsck()
               WHERE problem = 'recorded shape does not match its fingerprint'), '>', 0::bigint,
  'fsck oracle: a fingerprint that does not match its own columns is caught');
ROLLBACK TO s4;

SAVEPOINT s5;
INSERT INTO grove.trees (commit_sha, tbl, root_hash)
SELECT decode(repeat('cd',32),'hex'), 't', root_hash FROM grove.trees LIMIT 1;
SELECT is((SELECT count(*) FROM grove.fsck()
           WHERE problem = 'tree recorded for a commit that is not in the store'), 1::bigint,
  'fsck oracle: a tree left behind by a commit that is gone is caught');
ROLLBACK TO s5;

SAVEPOINT s6;
UPDATE grove.nodes n
SET keys = n.keys[1:1]
        || ARRAY[encode(convert_to(
             regexp_replace(convert_from(decode(n.keys[2], 'hex'), 'UTF8'), '\|$', '}'),
             'UTF8'), 'hex')]
        || n.keys[3:]
WHERE n.hash = (SELECT hash FROM grove.nodes
                WHERE level = 0 AND entries IS NOT NULL AND array_length(keys, 1) > 2 LIMIT 1);
SELECT cmp_ok((SELECT count(*) FROM grove.nodes n CROSS JOIN LATERAL unnest(n.keys) k
               WHERE convert_from(decode(k, 'hex'), 'UTF8') LIKE '%}'), '>', 0::bigint,
  'fsck oracle: the mis-filed key really is in the store');
SELECT cmp_ok((SELECT count(*) FROM grove.fsck()
               WHERE problem = 'rows are filed under a key that is not their own'), '>', 0::bigint,
  'fsck oracle: a row filed under the wrong key is caught, no hash covers the key');
ROLLBACK TO s6;

SELECT is((SELECT count(*) FROM grove.fsck()), 0::bigint,
  'fsck oracle: clean again once every corruption is rolled back');

SELECT * FROM finish();
ROLLBACK;
