# Running grove

Everything here is checkable from SQL. grove derives from your tables and never becomes the only copy,
so the worst honest outcome is always "throw the history away and rebuild it".

## Is it healthy

```sql
SELECT * FROM grove.health();          -- everything
SELECT * FROM grove.needs_attention(); -- only what wants a human
```

`needs_attention()` returning no rows is the green state. Poll it; alert on non-empty.

| flag | means | do |
| --- | --- | --- |
| `fsck problems` > 0 | a node is unreachable, malformed, or a tree does not hash to its root | see **fsck reports something** below |
| `journal awaiting commit` large | rows are being written faster than they are committed, or nobody is committing | commit, or stop tracking the table |
| `nodes packed by gc` low with many nodes | `gc` has not run and storage is larger than it needs to be | `SELECT grove.repack();` |
| `tracked tables` = 0 | grove is installed but versioning nothing | expected right after install, otherwise someone untracked |
| `merge in progress` | a merge stopped on conflicts and is waiting for a human | resolve them, then `merge_finish`, or `merge_abort` |
| `conflicts awaiting resolution` > 0 | rows the merge could not decide | `SELECT * FROM grove.conflicts WHERE NOT resolved;` then `grove.resolve_conflict(...)` |
| `bisect in progress` | someone started a bisect and never reset it | `SELECT grove.bisect_reset();` |
| `rebase in progress` | a rebase stopped part way | finish it, or `SELECT grove.rebase_abort();` |

## What happened, and how long it took

Every write verb records **one wide event** rather than a scatter of log lines. One row per
operation, with the high cardinality fields on it:

```sql
SELECT at, verb, ok, actor, branch, duration_ms, detail
FROM grove.events ORDER BY id DESC LIMIT 20;
```

```
verb     | ok | actor    | branch | duration_ms | detail
commit   | t  | app      | main   |       6.314 | {"sha": "f59dd63", "parent": "dd206e2", "journal_rows": 49, "tables": 1}
checkout | t  | app      | b1     |      53.636 | {"to": "b1", "from": "f59dd63", "rows": 0, "forced": false}
merge    | f  | app      | b1     |      31.002 | {"branch": "l", "merge_id": 2, "conflicts": 1, "finished": false}
repack   | t  | dba      | main   |    2801.440 | {"packed": 6, "nodes": 89, "bytes_before": 417792, "bytes_after": 425984}
```

Everything that changes history or data emits: `commit`, `checkout`, `branch`, `merge`,
`merge_finish`, `merge_abort`, `merge_octopus`, `resolve_conflict`, `cherry_pick`, `revert`,
`rebase`, `rebase_abort`, `reset`, `restore`, `stash_push`, `stash_pop`, `tag`, `tag_delete`,
`note_add`, `bisect_start`, `track`, `untrack`, `delete_branch`, `repack`, `prune`, `fetch`,
`receive`, `clone_from`. Every commit in the database has an event that created it, and the suite
enforces that, so a new verb cannot quietly bypass the log.

Ask it the questions you actually have:

```sql
SELECT verb, count(*), round(avg(duration_ms)) avg_ms, max(duration_ms) worst_ms
FROM grove.events GROUP BY verb ORDER BY 4 DESC;              -- what is slow

SELECT * FROM grove.events WHERE NOT ok ORDER BY id DESC;     -- what failed

SELECT * FROM grove.events
WHERE detail ->> 'sha' = 'f59dd63';                          -- who made this commit, and when
```

| setting | default | what it does |
| --- | --- | --- |
| `log_events` | `on` | write a row to `grove.events` per operation |
| `log_server` | `off` | also `RAISE LOG` the same event as one JSON line, for Loki, journald or CloudWatch |
| `log_retain_days` | `30` | `grove.repack()` deletes events older than this, so the table is self limiting |

Change one with `UPDATE grove.meta SET value = 'on' WHERE key = 'log_server';`.

Events live in the transaction that made them, so a rolled back operation leaves no row. The
history and the event log cannot disagree. The flip side: a **failed** operation usually rolls its
event back too. Turn on `log_server` if you need failures, because the Postgres log is not
transactional. Set `log_error_verbosity = terse` on the server to keep each event to one line.

## Who changed this row

```sql
SELECT col, actor, at, value, exact FROM grove.blame('products', '42');
```

`exact` is the column that matters. **true** means a journal entry proves that commit changed that
column. **false** means only that the value was already there at that commit. The change itself
happened earlier, in history grove no longer holds, either because the row predates `track()` or
because `prune` removed the commit that carried the evidence.

Never attribute a `false` row to a person. For an audit that has to stand up, filter:

```sql
SELECT * FROM grove.blame('products', '42') WHERE exact;
```

This is the direct cost of a retention policy: `prune` buys storage with attribution. If blame has
to be provable for N days, `prune` cannot cut closer than N days.

## Numbers for a dashboard

```sql
SELECT * FROM grove.metrics();
```

Returns `(metric, value)` numerics, ready to scrape: `grove_commits_total`, `grove_nodes_total`,
`grove_nodes_packed`, `grove_node_bytes`, `grove_journal_rows`, `grove_journal_pending`,
`grove_merges_open`, `grove_conflicts_unresolved`, `grove_events_total`, `grove_events_failed`,
`grove_commit_ms_p50`, `grove_commit_ms_p95`, `grove_commit_ms_max`,
`grove_seconds_since_last_commit`.

`health()` answers "is it healthy right now"; `metrics()` is the same database as time series.
Alert on `grove_conflicts_unresolved > 0`, `grove_journal_pending` climbing, and
`grove_commit_ms_p95` crossing whatever your writes can tolerate.

## The invariant that matters

Everything else is convenience. This is the one that must hold:

```sql
SELECT t.tbl
FROM grove.trees t
WHERE t.commit_sha = grove.resolve(grove.head())
  AND grove.write_tree(t.tbl::regclass) IS DISTINCT FROM t.root_hash;
```

No rows means every recorded tree still matches a full rebuild from the live table. Run it after any
incident. It costs a full rebuild per table, so schedule it rather than polling it.

## fsck reports something

1. `SELECT * FROM grove.fsck();` — it names what and where.
2. Run the invariant query above. If the trees still match, history is intact and the problem is in
   unreachable nodes: `SELECT grove.repack();` then `SELECT grove.prune(now() - interval '90 days');`
3. If a tree does **not** match, the recorded history disagrees with your data. Your data is right and
   the history is wrong. Recommit from the live tables:
   ```sql
   SELECT grove.commit('rebuild after fsck', grove.head());
   ```
4. If that still disagrees, drop the history and start again. Nothing of your data is at risk:
   ```sql
   TRUNCATE grove.nodes, grove.trees, grove.commits, grove.commit_parent, grove.changes CASCADE;
   SELECT grove.commit('fresh start', 'main');
   ```

## Scheduled work

| job | cadence | why |
| --- | --- | --- |
| `SELECT grove.repack();` | nightly | storage grows with commits until it runs; also rotates `grove.events` |
| `SELECT count(*) FROM grove.fsck();` | hourly | cheap, catches corruption early |
| the invariant query above | daily | expensive, and the only complete check |
| `SELECT grove.prune(now() - interval 'N days');` | weekly | bounds history; it is a retention policy, so pick N deliberately |

## Backup

`pg_dump` and `pg_restore` round-trip a tracked database whole — triggers, the canonical key index,
the tracked registry and every recorded tree. Verified: the restored database produces a bit
identical root hash and accepts new commits immediately.

Nothing special is needed. Back up the database.

## Who can do what

Nothing in `grove` is reachable until granted. Create the role, then pick a level:

```sql
SELECT grove.grant_read('analytics');   -- log, diff, blame, show
SELECT grove.grant_write('app');        -- and commit, branch, merge, revert
SELECT grove.grant_admin('dba');        -- and track, gc, prune, reset, unbundle
```

`unbundle` and `clone_from` accept data from elsewhere and are admin only for that reason. Column
types in a bundle are validated before any DDL runs, but the rest of a bundle is still someone else's
input.

## Postgres versions

16, 17 and 18, all in CI, all producing bit identical trees for the same data. A bundle written on
one is readable on another.

## Upgrading grove

`sql/install.sql` is idempotent — run it again. It refuses to install over a database whose on-disk
format it cannot read rather than corrupting it, and tells you what to run first. There is no
in-place format migration: if the format has moved, unpack, install, and repack, or rebuild the
history from your tables, which is always available.
