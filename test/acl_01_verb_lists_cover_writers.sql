BEGIN;
SELECT plan(7);

CREATE TEMP TABLE writers AS
SELECT DISTINCT p.proname
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'grove'
  AND p.prokind = 'f'
  AND p.proname NOT IN ('write_verbs', 'admin_only_verbs')
  AND p.prosrc ~* '(INSERT INTO|UPDATE\s+grove\.|DELETE FROM|TRUNCATE|CREATE TABLE|ALTER TABLE|DROP TABLE|CREATE TRIGGER|GRANT )';

SELECT cmp_ok((SELECT count(*) FROM writers), '>', 20::bigint,
  'access lists: the derivation finds the functions that write, so a broken pattern cannot pass quietly');

SELECT is((SELECT count(*) FROM writers w
           WHERE NOT (w.proname = ANY (grove.write_verbs()))
             AND NOT (w.proname = ANY (grove.admin_only_verbs()))), 0::bigint,
  'access lists: every function that writes is named in one of them, so a read role cannot call it');

SELECT ok('resolve_conflict' = ANY (grove.write_verbs()),
  'access lists: resolving one conflict is a write, like resolving all of them');
SELECT ok('fetch' = ANY (grove.admin_only_verbs()),
  'access lists: fetching is as privileged as receiving, both take a bundle from elsewhere');
SELECT ok('grant_level' = ANY (grove.admin_only_verbs()),
  'access lists: the function behind grant_read and grant_write is as privileged as they are');

CREATE ROLE grove_acl_probe;
SELECT grove.grant_read('grove_acl_probe');

SELECT cmp_ok((SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
               WHERE n.nspname = 'grove'
                 AND has_function_privilege('grove_acl_probe', p.oid, 'EXECUTE')), '>', 10::bigint,
  'access lists: a read role can still execute the reading functions, so the check below is not vacuous');

SELECT is((SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'grove'
             AND (p.proname = ANY (grove.write_verbs())
                  OR p.proname = ANY (grove.admin_only_verbs()))
             AND has_function_privilege('grove_acl_probe', p.oid, 'EXECUTE')), 0::bigint,
  'access lists: and it can execute none of the verbs either list names, whenever they were defined');

SELECT * FROM finish();
ROLLBACK;
