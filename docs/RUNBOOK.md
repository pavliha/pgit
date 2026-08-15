# Running pgit

Everything here is checkable from SQL. pgit derives from your tables and never becomes the only copy,
so the worst honest outcome is always "throw the history away and rebuild it".

## Is it healthy

```sql
SELECT * FROM pgit.health();          -- everything
SELECT * FROM pgit.needs_attention(); -- only what wants a human
```

`needs_attention()` returning no rows is the green state. Poll it; alert on non-empty.

| flag | means | do |
| --- | --- | --- |
| `fsck problems` > 0 | a node is unreachable, malformed, or a tree does not hash to its root | see **fsck reports something** below |
| `journal awaiting commit` large | rows are being written faster than they are committed, or nobody is committing | commit, or stop tracking the table |
| `nodes packed by gc` low with many nodes | `gc` has not run and storage is larger than it needs to be | `SELECT pgit.repack();` |
| `tracked tables` = 0 | pgit is installed but versioning nothing | expected right after install, otherwise someone untracked |

## The invariant that matters

Everything else is convenience. This is the one that must hold:

```sql
SELECT t.tbl
FROM pgit.trees t
WHERE t.commit_sha = pgit.resolve(pgit.head())
  AND pgit.write_tree(t.tbl::regclass) IS DISTINCT FROM t.root_hash;
```

No rows means every recorded tree still matches a full rebuild from the live table. Run it after any
incident. It costs a full rebuild per table, so schedule it rather than polling it.

## fsck reports something

1. `SELECT * FROM pgit.fsck();` — it names what and where.
2. Run the invariant query above. If the trees still match, history is intact and the problem is in
   unreachable nodes: `SELECT pgit.repack();` then `SELECT pgit.prune(now() - interval '90 days');`
3. If a tree does **not** match, the recorded history disagrees with your data. Your data is right and
   the history is wrong. Recommit from the live tables:
   ```sql
   SELECT pgit.commit('rebuild after fsck', pgit.head());
   ```
4. If that still disagrees, drop the history and start again. Nothing of your data is at risk:
   ```sql
   TRUNCATE pgit.nodes, pgit.trees, pgit.commits, pgit.commit_parent, pgit.changes CASCADE;
   SELECT pgit.commit('fresh start', 'main');
   ```

## Scheduled work

| job | cadence | why |
| --- | --- | --- |
| `SELECT pgit.repack();` | nightly | storage grows with commits until it runs |
| `SELECT count(*) FROM pgit.fsck();` | hourly | cheap, catches corruption early |
| the invariant query above | daily | expensive, and the only complete check |
| `SELECT pgit.prune(now() - interval 'N days');` | weekly | bounds history; it is a retention policy, so pick N deliberately |

## Backup

`pg_dump` and `pg_restore` round-trip a tracked database whole — triggers, the canonical key index,
the tracked registry and every recorded tree. Verified: the restored database produces a bit
identical root hash and accepts new commits immediately.

Nothing special is needed. Back up the database.

## Who can do what

Nothing in `pgit` is reachable until granted. Create the role, then pick a level:

```sql
SELECT pgit.grant_read('analytics');   -- log, diff, blame, show
SELECT pgit.grant_write('app');        -- and commit, branch, merge, revert
SELECT pgit.grant_admin('dba');        -- and track, gc, prune, reset, unbundle
```

`unbundle` and `clone_from` accept data from elsewhere and are admin only for that reason. Column
types in a bundle are validated before any DDL runs, but the rest of a bundle is still someone else's
input.

## Postgres versions

16, 17 and 18, all in CI, all producing bit identical trees for the same data. A bundle written on
one is readable on another.

## Upgrading pgit

`sql/install.sql` is idempotent — run it again. It refuses to install over a database whose on-disk
format it cannot read rather than corrupting it, and tells you what to run first. There is no
in-place format migration: if the format has moved, unpack, install, and repack, or rebuild the
history from your tables, which is always available.
