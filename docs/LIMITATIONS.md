# What grove does not do

Everything here is measured or deliberate. Numbers come from [../PERF.md](../PERF.md); nothing in
this document is an estimate presented as a result.

## Costs

**Reads are free.** Measured over three runs on a 1M-row table: 26–31 ms untracked, 26–29 ms tracked
— identical within noise. grove's triggers are write-side and your data never moves. Tracking does add
one expression index to the table, which is not free on the write path or in storage.

**Writes cost about 15 µs per changed row.** A 10,000-row `UPDATE` goes from 26–30 ms to 146–183 ms;
a 10,000-row `INSERT` from 6 ms to 91 ms.

Be careful with the multiplier: it is not stable, and quoting one is misleading. The tracked cost
holds steady, but the baseline moves — the same `UPDATE` measured 15 ms on freshly loaded pages and
26–30 ms once those rows had been written before, so identical overhead reads as anywhere from **5×
to 12×**. Design against the per-row figure.

The cost is the journal's *content*, not overhead: two full row images per changed row. Profiling
showed `to_jsonb` is about 5% of it; the rest is heap writes, WAL and index maintenance that no
amount of tuning avoids. Whether to keep both images is an open decision recorded in
`BUILD_PLAN.md`.

**Commit cost depends on where the changed rows are**, not only how many. On a 1.7M-row table: 500
scattered rows cost 336 ms, 5,000 scattered rows 1.6 s, and building the whole tree from nothing
12 s. Tables you did not touch cost nothing at all.

**`gc` trades read speed for storage.** Resolving a packed node walks its delta chain, and every
step is a jsonb parse and splice rather than a byte copy. At the default depth that costs **1.8–2.4×
on a diff** — 1,034 ms unpacked against 2,486 ms packed for the same 21,076 rows. On a 200k-row
fixture, by depth:

| `gc --depth` | node store | the same diff |
| --- | --- | --- |
| none | 109 MB | **958 ms** |
| **4 (default)** | **52 MB** | 2,403 ms |
| 16 | 46 MB | 3,651 ms |
| 50 | 46 MB | 3,664 ms |

Depth 50 is dominated by depth 16 — identical storage, identical read cost. Do not raise the depth
past the default expecting a free win; past 4 you are paying most of the read cost for the last
6 MB.

**Storage is roughly 2–3× your data, once you run `gc`.** The base snapshot is 0.26–1.0× the table
depending on row width — often smaller, since chunked images compress well. History is the variable
part: 10,000 commits on a 1M-row table left the node store at 4.5× the table until `gc`, then 1.8× at
the default depth and 1.2× at `--depth 50`. The journal adds about 300 bytes per changed row.

## Faster than git above ~50 MB, slower below it

Git's commit is O(file): it re-hashes and re-compresses the whole thing however little changed.
grove's is O(changed): it rewrites only the chunks holding changed rows. So there is a crossover, not
a verdict.

| same 12.7M rows | git | grove |
| --- | --- | --- |
| 28 MB of it, ~5,300 changed rows | **492 ms** | 1,801 ms |
| all 1.0 GB of it, 100 changed rows | 12,062 ms | **527 ms** |

Below roughly 50 MB git wins on constants — it hashes and zlib-compresses a byte stream, while grove
canonicalises every changed row and writes nodes durably under MVCC with WAL. Above it grove wins on
complexity, and the gap grows linearly.

**Diff is the exception and is genuinely slower**: 391 ms against 12.0 s over the same 30 commits,
both sides garbage collected — **31×**. Without `gc` on either side it is 7.6 s. That is the largest
open gap in the project, and most of what remains is the tree descent rather than delta application.

> [!note]
> This section said "it is not as fast as git, and will not be" for weeks. That was a 27× gap
> generalised into a law, and it did not survive being challenged — the gap is now 3.7× on the same
> fixture and inverted at 1 GB. Treat performance claims here as measurements with a date, not
> properties of the design.

The relevant comparison is not git. It is what else versions a *database* — Dolt and DoltgreSQL,
temporal tables, audit triggers — or having no version control on your data at all.

## Which PostgreSQL it runs on

**16, 17 and 18.** All three are in CI, and all three produce bit-identical trees for the same data —
checked, because a bundle written on one has to be readable on another.

16 is the floor only because that is the oldest one tested, not because 15 is known to fail. There is
one thing to watch when editing: grove used `min(bytea)`, which exists only on 18, and that silently
made 16 and 17 impossible to use at all — `commit` failed outright — until a version matrix existed
to notice. Any aggregate or function added in a recent major will do the same.

## Schema changes are not versioned

grove versions rows. It records the **shape** of each table per commit and uses it as a guard, but it
does not version DDL and cannot replay it.

- a commit after `ADD COLUMN` is a full rebuild, because every row's canonical form changed and no
  node can be reused
- every verb that writes live rows from a recorded tree **refuses** across a schema change rather
  than guess, naming the table, itself, and both column lists: `checkout`, `reset --hard`,
  `restore`, `stash pop`, `rebase`, `rebase abort`, `merge` and `cherry-pick`. A soft reset is
  exempt, since it moves the ref and writes no rows. A refusal leaves the thing you would need to
  retry it, so a stash still holds its rows and a parked rebase is still parked
- a renamed table is **detected** by content similarity and refused with both names and a match
  percentage — detected, not followed

Migrations own DDL. grove works alongside them; it does not replace them.

## Renaming a tracked table strands the history before it

History records a table by name. Renaming `t` to `u` and committing is supported, and
`grove.table_renames` will pair the two across the commits, but the commits made before the rename
still name `t` while the ones after name `u`. Checking out across that boundary needs both names to
exist as tables at the same time, and a rename leaves you with one.

So the working recovery is to put the other name back yourself: rename the table to what the commit
you are moving to calls it, and create an empty table under the name the commit you are leaving
calls it. `checkout` names the table it is missing so you can do that, rather than failing with a
bare `relation "t" does not exist` from somewhere inside the diff.

Doing this properly needs a stable table identity in `grove.trees` rather than a text name, which
would change the bundle format.

## History records the table name your session renders

A commit stores each table by name, and PostgreSQL renders a table's name relative to the session's
`search_path`: the same table is `t` from a session that has its schema on the path and `public.t`
or `app.t` from one that does not. grove now fixes the name at the first commit and reuses it for
every commit after, and resolves it back to a table when it needs to match history against what is
live, so a repository committed from one session behaves the same from another.

What it cannot do is resolve a name that does not resolve. If the first commit was made from a
session whose `search_path` made the name bare, `t`, then a later session without that schema on its
path cannot find the table at all, and `checkout` will say so by name. Tracking with a qualified
name, `grove.track('app.t')`, avoids the question entirely.

## Replaying history needs the table, or the server

Restoring rows must not fire the table's own triggers, or a checkout would run application logic
against data that is merely being put back. A superuser gets this for free: grove sets
`session_replication_role` and no trigger is touched. Everyone else has their triggers turned off and
restored around the replay, and turning a trigger off requires owning the table.

So a role that is neither a superuser nor the owner can commit, but cannot check out a table that has
any trigger of its own. It can check out tables that have none. grove says which trigger it could not
pause rather than leaving PostgreSQL's bare "must be owner of table" to be interpreted. Give the role
ownership, or run checkouts as the owner.

## log walks first parents, git's does not

`grove.log()` follows `parent_sha` and never the extra parents a merge records, so commits that came
in through a merge are not listed. `git log` shows them by default; `git log --first-parent` is the
equivalent of what grove does. Asking grove for the history of a row that arrived in a merge shows
the merge, not the commit on the branch it came from.

Nothing is lost. Those commits are reachable through `grove.ancestors`, and `blame` names the commit
that actually made the change rather than the merge that carried it. The walk stays first-parent
because `HEAD~N`, `rev` and `bisect` all count depth along it, and a walk that forked at every merge
would make those mean something else.

## One database holds one branch at a time

A checkout materialises a branch into your tables, exactly like git's working tree. Two branches
cannot be readable at once from the same database. If you need that, you need two databases and a
bundle between them.

## A commit claims every pending change, whoever made it

`grove.commit()` records every journal row that has not been committed yet, not only the rows the
caller wrote. Two people writing to the same database before either commits get one commit
containing both their changes, authored by whoever ran `commit`.

That follows from the model rather than being a defect: one database holds one branch, which is a
shared working tree, and `git commit -a` in a shared checkout behaves the same way.

What survives is the part that matters for an audit. The journal captures the actor on each row as
it is written, so `blame` still credits the right person even when the commit around it does not:

```sql
SELECT col, actor, exact FROM grove.blame('products', '42');
```

If you need commits that contain only one actor's work, serialise them. Take an advisory lock across
the write and the commit, or run the commit inside the same transaction as the writes, where MVCC
hides other sessions' pending rows from it.

## Pruning costs attribution, not data

`prune` deletes commits and the journal rows that explain them. The rows in your tables are
untouched and every surviving tree still rebuilds exactly, but `blame` loses the evidence for
anything the pruned commits changed. It does not guess: those columns come back with
`exact = false`, meaning "present at this commit, changed by something older than history".

Pick the retention window from how long attribution has to be provable, not from disk.

## grove does not move data over a network

`remote_add` records a name and a URL, and **nothing dials that URL**. It is a label saying where a
bundle came from, not a connection string. There is no `git://`, no ssh, no polling. A real
transport would need `dblink` or `postgres_fdw`, and grove is deliberately extension free.

Moving history is therefore yours to do, with whatever you already trust:

```bash
psql "$SRC" -At -c "SELECT grove.bundle(ARRAY['main'])" > pack.json
scp pack.json elsewhere:                       # or s3 cp, or a pipe, or email
psql "$DST" -v b="$(cat pack.json)" -c "SELECT grove.fetch('origin', :'b'::jsonb)"
```

`fetch` writes only `remotes/<name>/*`; `receive` moves local branches and enforces fast forward.
Both verify every node hashes to its content before storing it, so an untrusted courier is fine.
You just have to be the courier.

## Anything outside the database does not branch

Search indexes, object storage, payment providers, outbound notifications, caches. grove versions rows
in one database. Reverting a row does not un-send an email, and checking out a branch does not
reindex Meilisearch. Whatever else your application does in response to a write remains your
application's problem — which is why replay suppresses your triggers rather than re-firing them.

## Column and table shapes it handles, and one it does not

Handled, with tests:

- `GENERATED ALWAYS AS` columns — excluded from writes, recomputed by Postgres
- `GENERATED ALWAYS AS IDENTITY` keys — inserted with `OVERRIDING SYSTEM VALUE`
- columns named `n`, `o`, `cols`, `t`, `s`, `v`, `k` or `e`, which collide with identifiers the
  generated SQL uses. Row aliases are `"grove row"` and `"grove img"` — quoted and containing a space,
  so no unquoted column name can equal one. A table with a column of either of those two names is
  **refused at `track()`**, because the failure would otherwise be silent: `to_jsonb()` would resolve
  to the column instead of the row and every stored image would be a scalar
- a primary key whose keys all land on chunk boundaries, which cannot happen for large tables but is
  one small table in `chunk_target`. Such a level cannot shrink; the build collapses it instead of
  spinning to the depth cap
- composite primary keys, text primary keys, enums, `jsonb`, `numeric`, `timestamptz`, unicode

A composite primary key is handled everywhere the whole table is the unit: tracking, committing,
diffing, merging (a conflict names the row by every key column in canonical form), bundling and
cloning. It is **not** handled by the three verbs that address a single row by key, `blame`,
`log` with a `table:row` pathspec, and `restore` with a `table:row` pathspec. Those take one key
value as text and refuse a table with more than one key column rather than guess how to split it.
The refusal from `restore` is reached only when there is a differing row to consider; with nothing
to restore it returns zero without looking at the key.

Not handled: a table **without a primary key** cannot be tracked. There is no row identity to
version.

## Git verbs that are missing, and why

| | |
| --- | --- |
| `subtree`, `submodule` | no analogue — both compose *repositories*; there is one database here |
| signed commits | needs key management and a trust model that nothing else here has |
| `filter-branch` | history rewriting; `prune` truncates, but scrubbing a column out of the past means recomputing every tree forward of the rewrite point |
| following a table rename through a merge | detection exists; following means mapping old to new across the diff, conflict and journal paths |
| `rebase --continue` | a rebase that conflicts can only be aborted; resuming means replaying the rest of the range on top of a resolution, and nothing tracks where it stopped |

Octopus merges exist but follow git in refusing to resolve conflicts at all.

## Status

Pre-alpha. 1043 checks pass from an empty database, including 19 against a real 63-table application
schema, but nothing here has run in production and the on-disk format has changed twice this month.
There is no upgrade path between format versions other than rebuilding from your tables, which is
always possible because your tables are the source of truth — grove never becomes the only copy.
