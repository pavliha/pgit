BEGIN;
SELECT plan(5);

CREATE TEMP TABLE bodies AS
SELECT p.proname, p.prosrc
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'grove';

SELECT cmp_ok((SELECT count(*) FROM bodies), '>', 100::bigint,
  'no transport: there are functions to inspect, so the checks below are not looking at an empty set');

SELECT is((SELECT string_agg(proname, ', ') FROM bodies
           WHERE prosrc ~* '(dblink|postgres_fdw|pg_read_file|pg_ls_dir|lo_import|lo_export)'),
  NULL,
  'no transport: nothing reaches for another server or the file system');

SELECT is((SELECT string_agg(proname, ', ') FROM bodies WHERE prosrc ~* 'COPY\s+.*\bPROGRAM\b'),
  NULL,
  'no transport: and nothing shells out');

SELECT is((SELECT string_agg(e.extname, ', ')
           FROM pg_depend d
           JOIN pg_extension e ON e.oid = d.refobjid AND d.refclassid = 'pg_extension'::regclass
           JOIN pg_proc p ON p.oid = d.objid
           JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'grove'), NULL,
  'no transport: and no grove function depends on an extension, which is what the badge promises');

SELECT is((SELECT count(*) FROM pg_proc p
           JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'grove' AND p.proname = 'fetch'
             AND pg_get_function_identity_arguments(p.oid) LIKE '%jsonb%'), 1::bigint,
  'no transport: fetch is handed the bundle as data, so there is nothing for it to dial');

SELECT * FROM finish();
ROLLBACK;
