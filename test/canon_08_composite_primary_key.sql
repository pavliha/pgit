BEGIN;
SELECT plan(11);

CREATE TABLE sales (region text, sku text, qty int, note text, PRIMARY KEY (region, sku));
SELECT grove.track('sales');
INSERT INTO sales SELECT 'r'||(g%5), 'sku'||g, g, 'n'||g FROM generate_series(1,200) g;
SELECT grove.commit('base','alice');

SELECT is((SELECT array_to_string(pk_cols, ',') FROM grove.tracked), 'region,sku',
  'composite key: both columns are recorded as the key');

UPDATE sales SET qty = qty + 1 WHERE sku = 'sku7';

SELECT is((SELECT pk FROM grove.changes WHERE commit_sha IS NULL LIMIT 1),
  '{"sku": "sku7", "region": "r2"}'::jsonb,
  'composite key: the journal identifies the row by both columns');

SELECT grove.commit('bump one','bob');

SELECT is((SELECT count(*) FROM grove.diff(grove.rev('HEAD~1'), grove.rev('HEAD'))), 1::bigint,
  'composite key: the diff finds exactly the row that changed');
SELECT is(grove.write_tree('sales'),
  (SELECT root_hash FROM grove.trees WHERE commit_sha = grove.resolve('main') AND tbl = 'sales'),
  'composite key: the tree the commit recorded matches a full rebuild');
SELECT is((SELECT count(*) FROM grove.fsck()), 0::bigint,
  'composite key: and the store is clean, so the keys hash the way they are stored');

SELECT grove.branch('side');
SELECT grove.checkout('side');
UPDATE sales SET qty = 999 WHERE region = 'r1' AND sku = 'sku6';
SELECT grove.commit('side edit','bob');
SELECT grove.checkout('main');
UPDATE sales SET qty = 111 WHERE region = 'r1' AND sku = 'sku6';
SELECT grove.commit('main edit','alice');

CREATE TEMP TABLE mg AS SELECT grove.merge('side') AS n;
CREATE TEMP TABLE m AS SELECT id FROM grove.merges ORDER BY id DESC LIMIT 1;

SELECT is((SELECT convert_from(decode(c.k, 'hex'), 'UTF8') FROM grove.conflicts c
           WHERE c.merge_id = (SELECT id FROM m) LIMIT 1),
  'region=#2:r1|sku=#4:sku6|',
  'composite key: a conflict names the row by both columns in canonical form');

SELECT grove.resolve_all((SELECT id FROM m), 'ours');
SELECT ok(grove.merge_finish((SELECT id FROM m)) >= 0,
  'composite key: and the merge finishes');

SELECT throws_like($$ SELECT grove.blame('sales','r0') $$,
  '%row pathspec needs a single column primary key%',
  'composite key: blame cannot address such a row, and says so rather than guessing');
SELECT throws_like($$ SELECT grove.log(NULL,'sales:r0') $$,
  '%row pathspec needs a single column primary key%',
  'composite key: nor can log filtered to one row');
UPDATE sales SET qty = 5555 WHERE region = 'r0' AND sku = 'sku5';
SELECT grove.commit('one more change','dave');

SELECT is((SELECT count(*) FROM grove.diff(grove.rev('HEAD~1'), grove.rev('HEAD'))), 1::bigint,
  'composite key: there is a row to restore, so the refusal below is reached rather than skipped');

SELECT throws_like($$ SELECT grove.restore('HEAD~1','sales:r0') $$,
  '%row pathspec needs a single column primary key%',
  'composite key: nor can restore of one row, once it has a row to consider');

SELECT * FROM finish();
ROLLBACK;
