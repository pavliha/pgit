BEGIN;
SELECT plan(9);

CREATE TEMP TABLE facing(name text);
INSERT INTO facing VALUES
  ('commit'),('branch'),('checkout'),('delete_branch'),('merge'),('merge_finish'),('merge_abort'),
  ('merge_octopus'),('cherry_pick'),('revert'),('rebase'),('rebase_abort'),('tag'),('tag_delete'),
  ('note_add'),('note_delete'),('stash_push'),('stash_pop'),('bisect_start'),('bisect_reset'),
  ('resolve_conflict'),('resolve_all'),('track'),('untrack'),('untrack_missing'),('prune'),('repack'),
  ('reset'),('restore'),('remote_add'),('grant_level'),('log_rotate'),('fetch'),('receive'),
  ('clone_from');

SELECT cmp_ok((SELECT count(*) FROM facing), '>', 30::bigint,
  'audit surface: the list of verbs being checked is a real list, not a couple of names');

SELECT is((SELECT count(*) FROM facing f
           WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                             WHERE n.nspname = 'grove' AND p.proname = f.name)), 0::bigint,
  'audit surface: every verb named here exists, so none of them is a stale name');

SELECT is((SELECT count(*) FROM facing f
           JOIN (SELECT p.proname, string_agg(p.prosrc, ' ') AS src FROM pg_proc p
                 JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'grove' GROUP BY p.proname) b ON b.proname = f.name
           WHERE b.src NOT LIKE '%grove.emit%'), 0::bigint,
  'audit surface: and every one of them records what it did');

CREATE TABLE t (id int PRIMARY KEY, v text);
SELECT grove.track('t');
INSERT INTO t SELECT g, 'v'||g FROM generate_series(1,10) g;
SELECT grove.commit('base','alice');

SELECT grove.note_add('HEAD','a note');
SELECT grove.note_delete('HEAD');
SELECT is((SELECT count(*) FROM grove.events WHERE verb = 'note_delete'), 1::bigint,
  'audit surface: deleting a note is recorded, as adding one already was');

SELECT grove.remote_add('origin','somewhere');
SELECT is((SELECT count(*) FROM grove.events WHERE verb = 'remote_add'), 1::bigint,
  'audit surface: adding a remote is recorded, it decides where data may come from');

CREATE ROLE grove_audit_probe;
SELECT grove.grant_read('grove_audit_probe');
SELECT is((SELECT e.detail ->> 'level' FROM grove.events e WHERE e.verb = 'grant_level'), 'read',
  'audit surface: granting access is recorded, with the level that was granted');

SELECT grove.log_rotate();
SELECT is((SELECT count(*) FROM grove.events WHERE verb = 'log_rotate'), 1::bigint,
  'audit surface: rotating the log is itself recorded, so the audit trail cannot be emptied quietly');

SELECT grove.branch('side');
SELECT grove.checkout('side');
UPDATE t SET v = 'side' WHERE id = 1;
SELECT grove.commit('side','bob');
SELECT grove.checkout('main');
UPDATE t SET v = 'main' WHERE id = 1;
SELECT grove.commit('main','alice');
SELECT grove.merge('side');
SELECT grove.resolve_all((SELECT id FROM grove.merges ORDER BY id DESC LIMIT 1), 'ours');

SELECT is((SELECT e.detail ->> 'kind' FROM grove.events e WHERE e.verb = 'resolve_all'), 'ours',
  'audit surface: resolving every conflict at once is recorded, as resolving one already was');

SELECT grove.bisect_start('HEAD~1', 'HEAD');
SELECT grove.bisect_reset();
SELECT is((SELECT count(*) FROM grove.events WHERE verb = 'bisect_reset'), 1::bigint,
  'audit surface: abandoning a bisect is recorded, as starting one already was');

SELECT * FROM finish();
ROLLBACK;
