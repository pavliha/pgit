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

**Storage is roughly 2–3× your data, once you run `gc`.** The base snapshot is 0.26–1.0× the table
depending on row width — often smaller, since chunked images compress well. History is the variable
part: 10,000 commits on a 1M-row table left the node store at 4.5× the table until `gc`, then 1.8× at
the default depth and 1.2× at `--depth 50`. The journal adds about 300 bytes per changed row.

## It is not as fast as git, and will not be

Versioning the same 1.7M-row dataset over 30 commits, measured side by side, git commits in 492 ms
against pgit's seconds and diffs in 391 ms. Git hashes and zlib-compresses a byte stream; pgit
canonicalises every changed row, computes content-defined boundaries and writes nodes durably under
MVCC. That is not a constant factor apart.

What *is* comparable is the scaling property the design exists for: diff cost tracks the size of the
difference, not the history between two commits.

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
- columns named `n`, `o` or `cols`, which collide with the trigger's own identifiers
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

Pre-alpha. 530 checks pass from an empty database, including 19 against a real 63-table application
schema, but nothing here has run in production and the on-disk format has changed twice this month.
There is no upgrade path between format versions other than rebuilding from your tables, which is
always possible because your tables are the source of truth — pgit never becomes the only copy.
