# What pgit does not do

Everything here is measured or deliberate. Numbers come from [../PERF.md](../PERF.md); nothing in
this document is an estimate presented as a result.

## Costs

**Reads are free.** Measured over three runs on a 1M-row table: 26–31 ms untracked, 26–29 ms tracked
— identical within noise. pgit's triggers are write-side and your data never moves. Tracking does add
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
pgit's is O(changed): it rewrites only the chunks holding changed rows. So there is a crossover, not
a verdict.

| same 12.7M rows | git | pgit |
| --- | --- | --- |
| 28 MB of it, ~5,300 changed rows | **492 ms** | 1,801 ms |
| all 1.0 GB of it, 100 changed rows | 12,062 ms | **527 ms** |

Below roughly 50 MB git wins on constants — it hashes and zlib-compresses a byte stream, while pgit
canonicalises every changed row and writes nodes durably under MVCC with WAL. Above it pgit wins on
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

## Schema changes are not versioned

pgit versions rows. It records the **shape** of each table per commit and uses it as a guard, but it
does not version DDL and cannot replay it.

- a commit after `ADD COLUMN` is a full rebuild, because every row's canonical form changed and no
  node can be reused
- `checkout`, `merge` and `cherry-pick` **refuse** across a schema change rather than guess, naming
  the table and both column lists
- a renamed table is **detected** by content similarity and refused with both names and a match
  percentage — detected, not followed

Migrations own DDL. pgit works alongside them; it does not replace them.

## One database holds one branch at a time

A checkout materialises a branch into your tables, exactly like git's working tree. Two branches
cannot be readable at once from the same database. If you need that, you need two databases and a
bundle between them.

## Anything outside the database does not branch

Search indexes, object storage, payment providers, outbound notifications, caches. pgit versions rows
in one database. Reverting a row does not un-send an email, and checking out a branch does not
reindex Meilisearch. Whatever else your application does in response to a write remains your
application's problem — which is why replay suppresses your triggers rather than re-firing them.

## Column and table shapes it handles, and one it does not

Handled, with tests:

- `GENERATED ALWAYS AS` columns — excluded from writes, recomputed by Postgres
- `GENERATED ALWAYS AS IDENTITY` keys — inserted with `OVERRIDING SYSTEM VALUE`
- columns named `n`, `o`, `cols`, `t`, `s`, `v`, `k` or `e`, which collide with identifiers the
  generated SQL uses. Row aliases are `"pgit row"` and `"pgit img"` — quoted and containing a space,
  so no unquoted column name can equal one. A table with a column of either of those two names is
  **refused at `track()`**, because the failure would otherwise be silent: `to_jsonb()` would resolve
  to the column instead of the row and every stored image would be a scalar
- a primary key whose keys all land on chunk boundaries, which cannot happen for large tables but is
  one small table in `chunk_target`. Such a level cannot shrink; the build collapses it instead of
  spinning to the depth cap
- composite primary keys, text primary keys, enums, `jsonb`, `numeric`, `timestamptz`, unicode

Not handled: a table **without a primary key** cannot be tracked. There is no row identity to
version.

## Git verbs that are missing, and why

| | |
| --- | --- |
| `subtree`, `submodule` | no analogue — both compose *repositories*; there is one database here |
| signed commits | needs key management and a trust model that nothing else here has |
| `filter-branch` | history rewriting; `prune` truncates, but scrubbing a column out of the past means recomputing every tree forward of the rewrite point |
| following a table rename through a merge | detection exists; following means mapping old to new across the diff, conflict and journal paths |

Octopus merges exist but follow git in refusing to resolve conflicts at all.

## Status

Pre-alpha. 581 checks pass from an empty database, including 19 against a real 63-table application
schema, but nothing here has run in production and the on-disk format has changed twice this month.
There is no upgrade path between format versions other than rebuilding from your tables, which is
always possible because your tables are the source of truth — pgit never becomes the only copy.
