BEGIN;
SELECT plan(6);

SELECT is(grove.canon_settings() ->> 'hash_algo', 'sha256',
  'declared settings: the bundle declares sha256');
SELECT is(octet_length(grove.hash('anything'::text)), 32,
  'declared settings: and the code really does produce a 32 byte digest, so the label is true');

SELECT throws_like(
  $$ UPDATE grove.meta SET value = 'sha512' WHERE key = 'hash_algo' $$,
  '%hash_algo sha512 is not implemented%',
  'declared settings: hash_algo cannot claim an algorithm the code does not use');

SELECT throws_like(
  $$ UPDATE grove.meta SET value = '99' WHERE key = 'canon_version' $$,
  '%canon_version 99 is not implemented%',
  'declared settings: canon_version cannot claim a form the code does not write');

SELECT lives_ok(
  $$ UPDATE grove.meta SET value = 'sha256' WHERE key = 'hash_algo' $$,
  'declared settings: writing the value it already has is fine');

SELECT lives_ok(
  $$ UPDATE grove.meta SET value = '16' WHERE key = 'chunk_target' $$,
  'declared settings: chunk_target stays tunable, the code honours it');

SELECT * FROM finish();
ROLLBACK;
