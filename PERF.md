# Measured performance

All figures from `bench/`, run against Postgres 18 in the project's own container, on one laptop.
Scale is **1M rows** (a 73 MB table), not the 100M the acceptance criteria target — so every
comparison to a target is stated with that caveat rather than quietly rescaled.

Reproduce with `make bench`.

## Results after incremental tree maintenance

| Measurement | Before | After | Target | Verdict |
| --- | --- | --- | --- | --- |
| Commit touching **10** rows | 15,852 ms | **25 ms** | < 1000 ms at 100M | **634× faster** |
| Commit touching **1000** rows | 16,846 ms | **135 ms** | < 1000 ms at 100M | **125× faster, passes at 1M** |
| `diff` — 10 rows, **10,000 commits apart** | not runnable | **163 ms** | same cost as 1 commit apart | **AC-PERF-02 passes in full** |
| `diff` — 10 rows, 1 commit apart | 189 ms | **159 ms** | < 100 ms at 100M | miss on absolute, property holds |
| First commit (full build, 1M) | 18,723 ms | **9,780 ms** | — | unavoidably a full build |
| Commit after `ADD COLUMN` | 20,014 ms | **10,239 ms** | — | unavoidably a full build |
| 10k updates, trigger on | 266 ms | **141 ms** | within 2× of 14 ms | improved to **10.1×**, still a miss |
| 10,000 commits in **one** transaction | crashed — out of locks | **34 ms** mean per commit | — | scratch tables reused |

**AC-PERF-02 is the one worth reading twice.** Diffing 10 changed rows across **10,000 commits**
costs 163 ms — *less* than diffing the same 10 rows one commit apart (179 ms; the difference is
noise). Cost genuinely does not scale with history length, at the full figure the criterion asks
for. It could not even be attempted before the incremental work: 10,000 commits at 16 s each is
44 hours.

The first commit and any commit after a schema change stay full rebuilds by definition — there is
no previous tree to reuse in the first case, and no reusable node in the second.

## Results (original run, before the fix)

| Measurement | Result | Target | Verdict |
| --- | --- | --- | --- |
| `diff` — 10 rows differ | **189 ms** | < 100 ms at 100M | miss on absolute, **property holds** |
| `diff` — 1000 rows differ | **451 ms** | — | 100× the changes costs 2.4× the time |
| `diff --stat` — 10 rows differ | **118 ms** | — | — |
| `blame` — one row | **19 ms** | — | — |
| First commit (full tree build, 1M rows) | **18,723 ms** | — | — |
| Commit touching **1000** rows | **16,846 ms** | < 1000 ms at 100M | **miss** |
| Commit touching **10** rows | **15,852 ms** | < 1000 ms at 100M | **miss** |
| 10k updates, journal trigger off | **17 ms** | — | baseline |
| 10k updates, journal trigger on | **266 ms** | within 2× of baseline | **miss — 15.6×** |
| Commit after `ADD COLUMN` (AC-DDL-01) | **20,014 ms** | none set | ~25% above a normal commit |
| Node storage, 3 data commits | **98 MB** for a 73 MB table | none set | 134% overhead |
| Node storage, after a schema change | **195 MB** | none set | a schema change shares no nodes |

**AC-PERF-03 is now measured, by block counts rather than wall clock as the criterion requires.**
Across a 50-table database, `diff --stat` fetches **494 blocks** from `pgit.nodes` when one table
changed and **24,700** when all fifty did — a ratio of exactly **50.0**. Reads scale with the number
of *changed* tables and cost nothing for unchanged ones, because an untouched table keeps a bit-
identical root hash and the descent short-circuits before reading a single node.

Not run, and not claimed:

| Criterion | Why |
| --- | --- |
| Everything at 100M | the 1M run locates every bottleneck found so far; 100M would scale the same shapes. **Nothing here is evidence about 100M.** |

## What the numbers say

**The read side works.** Diffing 10 changed rows out of a million costs 189 ms, and diffing 1000
costs 451 ms — 100× the changes for 2.4× the time. That is the O(difference) property the whole
storage design was chosen for, holding on real data. The absolute number misses a target set at
100× the scale, but the shape is right and the constant is the tractable part.

**The write side does not, and the cause is structural, not a constant.** Commit cost is
*flat* — 15,852 ms for ten changed rows, 16,846 ms for a thousand, 18,723 ms to build from
nothing. `pgit.write_tree` rescans and rehashes the entire table on every commit. The design
document said tree maintenance should happen "over the touched keys only"; the implementation does
a full rebuild. Nothing about the storage model is wrong — the maintenance algorithm is simply the
naive one.

**Write amplification is 15.6×, not the 2× the criteria allow.** The journal trigger fires per row
and does a jsonb key extraction and an insert for each.

## The schema-change number (AC-DDL-01)

Adding a column to a 1M-row table costs **20.0 s** to commit, against 15.7–16.2 s for an ordinary
commit. Today that difference is small only because *every* commit is already a full rebuild. The
number matters for what comes next: once incremental maintenance lands, ordinary commits should
fall by orders of magnitude while `ADD COLUMN` stays at full-rebuild cost, because changing the
column set changes every row's canonical form and no node can be reused.

That also shows up in storage — node storage went from **98 MB to 195 MB** when the schema changed,
since the new tree shares nothing with the old one. Both facts belong in the README before anyone
runs a migration on a large tracked table.

## History costs storage, and the number is large

The 10,000-commit run grew `pgit.nodes` to **540 MB against a 107 MB table — five times the data it
versions.** None of it is garbage: every one of those commits is reachable from `main`, so no
collector could reclaim any of it.

The arithmetic is straightforward once stated. Each commit rewrites the leaf chunk containing the
changed rows plus its ancestors — roughly four nodes — and a level-0 node carries the **full row
image** of all ~64 rows in its chunk. Ten thousand commits therefore rewrite ~640,000 row images
even though only 100,000 row versions were actually written.

Three consequences, none of them a bug, all of them things an adopter must know before turning this
on:

- Storage grows with **number of commits**, not with data size. A busy table committed per request
  will outgrow itself quickly.
- Dropping the leaf `v` image would remove most of this, at the cost of `diff` no longer being able
  to emit before/after images without reading the live table. That is the same trade-off as
  AC-PERF-05 above, and the same decision.
- There is no `pgit gc` and, for a linear history, nothing for it to collect. What is actually
  needed is a **retention policy** — dropping unreachable nodes after history is truncated — which
  does not exist yet.

Mean commit cost in one long transaction also grew from **16 ms at 500 commits to 34 ms at 10,000**,
as `pgit.changes` accumulated 100,000 rows and the node table grew. Roughly 2× for 20× the commits.

## Why write amplification is still 10× (AC-PERF-05)

Moving from a per-row trigger to `FOR EACH STATEMENT` with transition tables took 10,000 updates
from 266 ms to 141 ms against a 14 ms baseline — from 19× to **10.1×**. The target is 2× and this
does not reach it.

The remaining cost is not per-statement overhead, it is the **content**: every journalled row builds
two `jsonb` images and inserts them, so a 10,000-row update writes 20,000 jsonb objects on top of
the 10,000 row versions Postgres already wrote. Roughly 2× the data of the write itself, plus index
maintenance on `pgit.changes`.

Three ways to close it, none of them free, none taken:

1. **Drop the `before` image.** It is recoverable from the parent commit's tree via `pgit.lookup`.
   That halves journal volume, but `blame` reads before/after per column and the revert conflict
   guard compares against it, so both would need reworking to read the tree instead.
2. **Journal only changed columns** rather than whole rows. Smaller, but makes every consumer
   reconstruct full images.
3. **Accept it and document it.** A journal that captures full row images cannot plausibly cost
   2% of the write it describes; a 2× target may simply be the wrong number. **That is a judgement
   for Pavlo, not something to quietly rewrite in the criteria.**

## The two fixes, in priority order

1. **Incremental tree maintenance.** On commit, take the changed keys from the journal, rehash only
   the leaf chunks containing them and the ancestors of those chunks, and reuse every other node by
   hash. Cost becomes O(changed × depth) instead of O(table). This is the single change that moves
   commit from ~16 s to the target, and it unblocks AC-PERF-02 and -03.
2. **Statement-level journal trigger.** Replace the per-row trigger with a `FOR EACH STATEMENT`
   trigger using `REFERENCING OLD TABLE`/`NEW TABLE`, so a 10,000-row update journals with one
   `INSERT … SELECT` instead of 10,000 individual inserts.

Neither is a redesign. Both were anticipated in the design and neither was built, which is why this
file exists before the optimisation rather than after it.

> [!note] The 134% storage overhead comes from level-0 entries carrying the full row image (`v`)
> as well as its hash. That was a deliberate choice in the diff-core tick — a diff cannot emit
> before/after images from hashes alone. It is worth revisiting only if adoption feedback says so;
> git stores blobs too.
