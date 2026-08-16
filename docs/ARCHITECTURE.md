# How grove works

grove versions **rows**, in one Postgres database, using git's storage model. There is no forked
engine and no C extension: everything here is SQL and PL/pgSQL running on a stock server.

This document is the internals. For day-to-day use see [USAGE.md](USAGE.md); for what it will not do
see [LIMITATIONS.md](LIMITATIONS.md); for numbers see [../PERF.md](../PERF.md).

## Two layers, because writes and reads want opposite things

| | `grove.changes` — the journal | `grove.nodes` — the tree |
| --- | --- | --- |
| written by | statement triggers, as you write | `grove.commit()`, in bulk |
| holds | before and after images per changed row | content-addressed nodes |
| serves | `revert`, `rebase`, `cherry-pick`, `blame` | `diff`, `merge`, `checkout` |
| canonical | no | **yes** |

The journal is an append-only record of what happened. The tree is a statement of what *is*. Two
databases that agree on content agree on the tree bit for bit, whatever order they got there in —
which is the property everything else is built on.

## The canonical row form

Before anything is hashed it is rendered into one text form, so that two rows are identical exactly
when Postgres would consider them equal:

- columns sorted by name, each rendered as `name=#<length>:<value>|`, with `~` for NULL
- the length prefix makes the framing unambiguous, so no value can impersonate a delimiter
- `numeric` goes through `trim_scale`, so `5.00` and `5.0` agree; signed zero and NaN are pinned
- `text` goes through `normalize(x, NFC)`, so equal unicode agrees regardless of composition
- `timestamptz` renders in UTC to microseconds; enums render by **label**, not oid, so a dump and
  restore that renumbers the catalogue does not change a hash
- domains render as their base type

That form is hashed with `sha256` from core — no `pgcrypto` dependency. The rules are versioned in
`grove.meta.canon_version`; changing them changes every hash, so it is a format break, not a setting.

## Content-defined chunking

Rows are grouped into chunks by a property **of the key alone**:

```
is_boundary(key) ⇔ first 3 bytes of hash(key) mod chunk_target = 0
```

`chunk_target` defaults to 64. Because the boundary depends only on the key and not on position or
history, inserting a row does not reshuffle its neighbours into different chunks, and two databases
chunk identical content identically. That is what makes `diff A B` cost O(size of the difference)
rather than O(history) or O(table).

It also has a consequence used throughout the write path: **only an inserted or deleted key can move
a boundary.** An UPDATE that leaves keys alone cannot change the shape of the tree at all.

Chunk sizes are geometric, not uniform — a target of 64 produces plenty of nodes far larger. Smaller
targets have been measured repeatedly and are worse: more levels and more nodes cost more than the
smaller nodes save.

## The node format

A node is one row in `grove.nodes`:

| column | holds |
| --- | --- |
| `hash` | the node's identity |
| `level` | 0 for leaves, upward from there |
| `keys text[]` | child keys, in order |
| `hashes bytea` | child hashes, packed at a 32-byte stride, same order |
| `entries jsonb` | row images for a leaf; `[]` for an internal node |

**`hashes` is exactly the pre-image of `hash`** — `grove.hash(hashes) = hash`, by construction. That
is not a cache to be invalidated; it is the thing the hash is taken of. It makes rehashing a node a
single call, and lets a changed child be spliced in with `overlay` rather than by rebuilding the
node from its parts.

Nothing is duplicated between the three columns, which is what keeps the format smaller than the
jsonb-of-`{k,h,v}` it replaced as well as faster.

`grove.node_items(hash)` is the single accessor: it yields `(k, ch, v)` per child and every reader
goes through it. `grove.node_entries(hash)` is the same without the images, for the descent, and
`grove.node_raw(hash)` returns the three columns unexpanded for callers that compare hashes as bytes.

Both vectors are walked once with `unnest ... WITH ORDINALITY` and paired on the ordinal. **Never
subscript `keys[i]` in a loop**: a `text[]` holds variable-length elements, so Postgres walks the
array from the start for every subscript, and iterating a 674-entry node that way costs ~227,000
element steps. A node's parts are resolved through its delta chain only when it has one — the
accessors branch on `entries IS NOT NULL` and `CASE` short-circuits, so an unpacked node never calls
the resolver.

## Identifiers the generated SQL reserves

Much of grove is SQL generated per tracked table, and generated SQL has to alias the user's table.
Any bare alias can collide with a column of the same name, and the failure is silent rather than
loud: `to_jsonb(t)` over `FROM tbl t` resolves `t` to the **column** when one exists, so the row
image becomes that column's scalar value and the wrong tree is stored. Nothing complains until a
replay tries to build a record from it, long after the damage.

The aliases are therefore `"grove row"` for the table and `"grove img"` for a populated record. Both
are quoted and contain a space, so no unquoted column name can equal them. A table carrying a column
of either name is **refused by `track()`**, because a prefix alone is not enough — `grove_t` collides
with a column named `grove_t`. `test/journal_06_hostile_columns.sql` tracks a table whose columns are
named after every alias the codebase has ever used.

Scratch tables that hold keys are declared `COLLATE "C"`. Keys are hex and every ordering in the
tree is byte order, so C collation is needed both for correctness and so the indexes on those tables
are usable for the range probes that locate a changed key's chunk.

## Writing a commit

`grove.commit()` snapshots every tracked table and records one commit row.

For each table it takes the keys the journal says changed and splices only what those touch:

1. no changed keys → **the parent's root is reused unchanged**, at no cost
2. changed keys → locate each key's chunk with one indexed probe, rebuild those chunks, then rebuild
   the levels above them
3. if the touched chunks cover most of the tree, fall back to a full rebuild, which is one
   sequential pass and cheaper past roughly three quarters coverage

A pure-update commit rebuilds each touched chunk in place: `array_position` finds the entry,
`overlay` replaces its 32 bytes of hash, `jsonb_set` replaces its image. No step produces a row per
entry, which is what made this expensive before.

Because boundaries cannot move under pure updates, the touched region is **not** widened to
neighbouring chunks in that case. It is widened by one chunk either side when keys were inserted or
deleted, since a boundary may then have split or merged.

## Reading a diff

`grove.diff(a, b)` descends both trees together, pairing children whose key ranges overlap and
pruning any pair whose hashes are equal — an unchanged subtree costs one comparison.

Resolution is deliberately in two parts, and the subtlety matters:

- a key the descent saw on **both** sides is decided by comparing its row hashes, no lookup
- a key seen on **one** side only is ambiguous and needs a point lookup

The descent skips chunk pairs that are *identical*, so an unchanged row can surface from one side
while its counterpart sits in a chunk that was never visited. Treating one-sided keys as inserts or
deletes reports rows that never changed; a contiguous range delete triggers it. `diff_05` in the test
suite computes the same diff by full-scanning both trees and joining on the key, sharing no code with
the descent, and exists to catch exactly that.

## Merging

Three-way per row, against the merge base, per column. Two branches that changed different columns of
the same row merge cleanly; the same column changed differently is a conflict, recorded in
`grove.conflicts` with base, ours and theirs so it can be resolved with SQL.

The merge applies **with your constraints live**. It does not use replica mode, because the point is
that Postgres validates the result: a merge that would dangle a foreign key, break a unique index or
fail a check aborts on its own. Deferred constraints are set deferred during the apply and immediate
before the commit, so the whole merged state is validated as a unit.

Octopus merges follow git and refuse to resolve conflicts at all: heads that agree are applied,
anything else is refused by name.

## Replay, and running without superuser

`revert`, `checkout`, `rebase` and `cherry-pick` replay recorded state. They must not re-fire your
application's triggers, so they call `grove.replay_begin()`, which tries
`session_replication_role = replica` and, on `insufficient_privilege`, falls back to disabling each
non-grove trigger by name and restoring its exact prior state afterwards.

The fallback is arguably better: `DISABLE TRIGGER` skips internal triggers, so referential integrity
stays enforced during replay, which replica mode does not. It costs an ACCESS EXCLUSIVE lock per
tracked table for the duration.

grove's own journal triggers are `ENABLE ALWAYS`, so they still fire under replica mode — replay is
real history, not an invisible edit.

## Storage over time

Every commit that touches a chunk writes a new version of it, so the node store grows with commit
count. `grove.repack()` — `grove gc` — rewrites older versions as deltas against newer ones, using
git's copy/insert op-list format: a delta is a list of "copy these bytes from the base" and "insert
these literal bytes" instructions, applied with `substring` and concatenation.

Deltas align entries **by position**, which is exact for two versions of a chunk whose membership has
not changed and degrades to a larger delta — never a wrong one — when it has. Every delta is verified
against its target when built and falls back to a whole-node insert if it would not reconstruct
exactly, so correctness never depends on the delta logic being clever.

A node's hash is the hash of its content, not of its storage, so packing and unpacking never change
an identity. `grove unpack` reverses it.

## Settings

`grove.meta` holds everything tunable, read through `grove.setting(key)`. All of these are read once
per commit or per build, never per row.

| key | default | what it decides |
| --- | --- | --- |
| `chunk_target` | 64 | average rows per leaf chunk. Measured at both scales; see PERF.md before changing it |
| `max_tree_depth` | 40 | how many levels a build may produce before it gives up |
| `max_incremental_keys` | 10000 | above this many changed keys, commit rebuilds the tree instead of splicing |
| `rebuild_when_hit_fraction` | 0.75 | rebuild rather than splice once this fraction of the tree is touched |
| `splice_max_changes_per_chunk` | 8 | splice only while changes are this sparse within the chunks they touch |
| `canon_version`, `hash_algo`, `delta_format` | — | format identity, not tuning. Changing one invalidates every stored hash |

The last three thresholds only choose *how* a commit reaches its answer, never what the answer is:
splicing a chunk and rebuilding its key range must produce the same tree, and both must equal a full
rebuild. `test/settings_01_tuning.sql` forces each path and asserts all three agree.

## Invariants, and where they are checked

- a node's hash is `grove.hash` of its packed child hashes — `fsck`
- `keys` and `hashes` agree in length — `fsck`
- every child hash and every commit parent exists — `fsck`
- the incrementally spliced tree equals a full rebuild of the same rows — `incremental_01`, `_04`,
  `_05`, `_06`
- `diff` agrees with a full scan of both trees — `diff_05`
- `diff` agrees with an independent replay of the journal — `diff_03`
- a bundle's nodes hash to their content on receipt — `unbundle`, and the remote suite tampers one

If you change anything in this document, those are the tests that decide whether you were right.
