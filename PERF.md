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

### AC-PORT-02, finally run

`test/rds_test.sh` creates a plain `LOGIN` role with no superuser rights and exercises the whole verb
set against it. That is **stricter than RDS**, where the master user is `rds_superuser`.

It found one real dependency: `session_replication_role` is superuser-only, so **`revert` and
`checkout` failed outright** — everything else already worked. Both now call `pgit.replay_begin()`,
which tries the session GUC and, on `insufficient_privilege`, falls back to disabling each
non-pgit trigger by name and restoring its exact prior state afterwards.

The fallback is arguably the better path: `DISABLE TRIGGER` skips internal triggers, so **referential
integrity stays enforced during replay**, which closes the FK gap that replica mode left open. It
costs an ACCESS EXCLUSIVE lock per tracked table for the duration of the replay.

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

Storage grows with **number of commits**, not with data size. A busy table committed per request
will outgrow itself quickly. There is no `pgit gc`, and for a linear history there would be nothing
for it to collect — what is actually needed is a **retention policy**, which does not exist yet.

### Two things measured here, one of which overturned the obvious fix

**Separating blobs from trees, git-style, makes it worse.** The obvious fix looks like git: leaf
nodes should hold `(key, hash)` only, with row images in a separate content-addressed blob table, so
changing one row does not rewrite its 63 unchanged neighbours. Measured on 20k rows and 300 commits:

| Layout | Size |
| --- | --- |
| Current — images inline in the chunk | **7,784 kB** |
| Git-style — nodes 7,120 kB + blobs 6,664 kB | **13 MB** |

Worse by 1.7×. The reason is compression context: pglz compresses a whole 64-row chunk as one unit,
while 20,300 individually-stored blobs are each far below the TOAST threshold and get no compression
at all. **The inline layout is accidentally closer to a git *packfile* than to git's loose objects**
— and batching for the compressor is exactly why git packs.

**`chunk_target` — measured at both scales, and the answer inverts.** At 20k rows, 16 looked like a
29% storage win over 64. At 1M rows it is a **loss on storage and a rout on commit speed**:

| | target 64 | target 16 | verdict |
| --- | --- | --- | --- |
| Initial commit (full build) | 9,638 ms | 9,730 ms | same |
| **Commit 10 rows** | **20 ms** | 98 ms | **64 wins, 4.9×** |
| **Commit 1000 rows** | **133 ms** | 830 ms | **64 wins, 6.2×** |
| **Mean per commit over 200** | **16 ms** | 92 ms | **64 wins, 5.8×** |
| Diff 10 rows | 119 ms | **56 ms** | 16 wins, 2.1× |
| Diff 1000 rows | 439 ms | **177 ms** | 16 wins, 2.5× |
| Diff across 200 commits | 599 ms | **198 ms** | 16 wins, 3× |
| **Node storage** | **104 MB** | 132 MB | **64 wins, 27%** |
| Node count | 16,711 | 67,681 | — |
| Tree depth | 3 | 4 | — |

The mechanism is depth. A smaller chunk makes each leaf rewrite cheaper but makes the tree deeper,
and **every commit rewrites one node per level**. At 20k rows the tree is shallow enough that the
smaller leaf wins; at 1M rows the extra level plus 4× the nodes costs more than the leaf saves — and
`nodes_at_level(root, 1)`, which the incremental splice enumerates on every commit, grows from ~244
entries to ~3,900.

Diff moves the other way because a smaller chunk is a finer candidate granularity: the descent
gathers whole chunks as candidates, so smaller chunks mean fewer spurious rows to resolve by point
lookup.

**Conclusion: keep 64.** Commits are far more frequent than diffs on a write path, 64 wins commits
by ~6× and storage by 27%, and 119 ms for a diff is already acceptable. The real lesson is that the
optimum is **scale-dependent**, so any fixed constant is wrong in principle — auto-tuning
`chunk_target` from table size would beat both. And if diff latency is what matters, the lever is
narrowing the candidate set, not shrinking chunks.

**Hoisting column names out of the row images saves nothing.** Each row image is a jsonb object
repeating every column name, 64 times per chunk. A columnar layout — column names once, values as
parallel arrays — measures **7,664 kB against 7,800 kB, a 1.7% saving**. pglz has already erased the
repetition.

### The principle these three measurements establish

Every layout change tried so far fails for the same reason. **Compression already captures the
redundancy *inside* a node.** Blob separation, smaller chunks and columnar encoding all rearrange
data within or around a node, and pglz was already handling that.

What compression cannot capture is redundancy **between versions of a node**, because each node is
compressed independently. Three hundred versions of one chunk, differing by a single row, are stored
three hundred times over. That is exactly the gap git closes with packfile deltas — and it means
there are only two ways to control storage here: **store fewer node versions, or delta them.**

Concretely, a commit costs roughly **one leaf chunk plus one node per tree level** — about 40 KB at
1M rows — **regardless of whether it changed one row or sixty-four.** Committing the same region a
hundred times costs a hundred chunk versions; batching those changes into one commit costs one.

## Delta compression between node versions

Built as a **repack step**, the way git does it: the write path is untouched and commits stay at
25 ms, then `pgit.repack()` — `pgit gc` from the CLI — rewrites older versions of a chunk as deltas
against the next newer one. Content addressing is preserved because a node's hash stays the hash of
its logical content; the delta is purely a storage form. `pgit.unpack()` reverses it.

Measured on 20k rows and 300 commits, with `VACUUM FULL` so the on-disk numbers are real.

**The delta format has been rewritten twice.** The first version applied a delta by expanding the
entries to rows, anti-joining, and re-aggregating with a sort — O(chunk) relational work *per hop*.
The second stored each delta as `(prefix_len, suffix_len, middle)` against the serialised node and
applied it with `substr` and `||`, which are memcpy inside Postgres: a chain splices text through
every hop and parses jsonb **once at the end** instead of rebuilding at each step.

The third is **git's format — a copy/insert op list** — because one splice has a failure mode that
matters. A single `(prefix, suffix, middle)` can only describe *one* contiguous changed region, so
two rows changed at opposite ends of a chunk force the middle to span everything between them. Git
does not have this problem because a packfile delta is a sequence of instructions: copy N bytes from
the base at offset O, or insert these literal bytes.

`pgit.make_delta` now aligns base and target entries by key and, per target entry, emits either a
copy of that entry's byte range in the base or — when the entry changed — a prefix copy, an insert
of the differing middle, and a suffix copy. Adjacent copies that are contiguous in the base coalesce,
so a run of unchanged entries collapses to a single op. Applying is still pure memcpy.

Measured on the **same 424 consecutive node-version pairs**, from a workload that changes two
unrelated rows per commit — the case one splice cannot express:

| | one splice | op list |
| --- | --- | --- |
| pairs whose delta beats the full node | 370 of 424 | **424 of 424** |
| total delta bytes over all pairs | 646 kB | **150 kB** |
| mean leaf delta, against a 9,057 B node | 3,398 B — 37% | **541 B — 6%** |

End to end on that fixture at depth 50: **2,506 kB → 473 kB, 81% off**, averaging 3.6 ops and 361
bytes per delta with no fallbacks. Under one splice the same fixture packed only 118 of 424 versions
and came out 1.6% smaller, because most candidate deltas failed the "is this smaller than the node"
check outright.

Two things this cost, both recorded because they were nearly invisible. The first version emitted the
array separator as a copy from a **fixed** base offset, so no two copies were ever contiguous, nothing
coalesced, and a 123-entry leaf produced 247 ops and a delta *larger* than the node — it packed the
same node count while saving nothing. The separator has to be copied from the position following its
own entry. And every delta is now verified against its target at construction time, falling back to a
whole-node insert if it would not reconstruct exactly, so correctness does not depend on the offset
arithmetic being right.

| max_depth | node storage | diff, relational delta | diff, byte splice |
| --- | --- | --- | --- |
| 0 (off) | 7,856 kB | 167 ms | 213 ms |
| 1 | 5,192 kB — 34% off | 186 ms | 312 ms |
| **4 (default)** | **3,608 kB — 54% off** | 359 ms | **251 ms** |
| 16 | 2,856 kB — 64% off | — | 472 ms |
| 50 | 2,632 kB — 66% off | **7,071 ms** | **1,248 ms** |
| 200 | 2,560 kB — 67% off | — | 4,184 ms |

At depth 50 the rewrite is **5.7× faster**. That moved the practical default from 1 to **4**: 54% of
the node store for a read cost inside run-to-run noise, where before 54% would have cost 2× on reads.
Depth 16 is available for 64% at roughly 2× reads.

Run-to-run variance on these timings is around 25% — the depth-0 baseline measured 167 ms and 213 ms
on two runs — so only the large gaps here are meaningful.

### Commit cost depends on the shape of the change, not just its size

Every commit figure quoted above comes from a fixture that updates **ten adjacent rows**, which is
the most favourable case there is. Versioning a real dataset showed how far that generalises. On a
1.7M-row table with a text primary key:

| change | before | after | |
| --- | --- | --- | --- |
| 100 adjacent rows | 45 ms | 50 ms | |
| 5,000 adjacent rows | 1,402 ms | **125 ms** | 11× |
| 500 scattered rows | 6,761 ms | **2,424 ms** | 2.8× |
| 5,000 scattered rows | 53,183 ms | **13,368 ms** | 4.0× |
| 50,000 scattered rows | — | 18,502 ms | bounded |
| *full rebuild of the table, for reference* | *17,084 ms* | | |

**Scattering 5,000 changed rows across the table cost 38× what changing 5,000 adjacent rows cost,
and 3.1× what rebuilding the entire table from scratch cost.** The changed row count cannot express
this — the two workloads differ only in where the rows are.

Two causes, both now fixed. The first was quadratic: locating which chunk each changed key belongs to
tested *every* chunk against the *whole* changed array, `O(chunks × keys)`. At 1.7M rows that is 132
million comparisons and it was 40 s of a 57 s commit. It is now one indexed range probe per changed
key. The scratch tables carry a `COLLATE "C"` index for it, which the keys wanted anyway — they are
hex, and every other ordering in the tree is byte order, so the default collation was a latent
inconsistency as well as an unusable index.

The second is that splicing cost tracks chunks touched while a rebuild is one flat sequential pass,
so past about three quarters of the tree the rebuild simply wins. There is now a bail-out at that
point. It is deliberately not tuned tighter: an earlier attempt bailed at one sixth and made 500
scattered rows **2.5× slower** (6.8 s → 17.2 s) by forcing a rebuild that was not yet worth it. The
threshold exists to bound the worst case, not to second-guess the common one.

### At 1M rows and 10,000 commits — the number the README used to get wrong

The 20k figures above are a fixture. This is the real one: a 1M-row table, 10,000 commits each
touching the same ten rows, `VACUUM FULL` between every measurement.

| | node store | × the table | off | 
| --- | --- | --- | --- |
| no repack | 487 MB | 4.5× | — |
| **`gc` at the default depth 4** | **197 MB** | **1.8×** | **60%** |
| `gc --depth 16` | 146 MB | 1.3× | 70% |
| `gc --depth 50` | 131 MB | 1.2× | 73% |
| `gc --depth 200` | 126 MB | 1.2× | 74% |

**"10,000 commits grew the node store to 5× the table" was a pre-`gc` number**, and it was the
headline in the README for weeks. Packed, the same history is 1.2–1.8×, and the curve has plateaued
by depth 50 — the residual 126 MB is essentially one full snapshot of a 108 MB table, which is the
floor any content-addressed store has. Storage is not the open problem it was recorded as; the open
problem is **retention policy**, which is a different question.

Read cost is what limits depth, not storage. On the old one-splice format, measured cleanly: 169 ms
at depth 4, 428 ms at 16, 411 ms at 50, and 6,225 ms at 200 — so depth 50 is the last free stop and
200 is a cliff. The op-list format's depth-16-and-beyond timings were taken while other work shared
the machine and are not trustworthy; the sizes in the table are unaffected by that, timings are not.

> [!warning]
> **Do not hold a transaction open while a storage benchmark runs.** An at-scale re-run of the table
> below reported the node store *growing* under repack. It had not: live data was 92 MB of entries
> plus 15 MB of deltas, and the TOAST table was 953 MB of tuples `VACUUM FULL` was not allowed to
> remove, because progress was being polled with `SELECT pg_sleep(300)` — a five-minute snapshot that
> holds back the vacuum horizon for the whole database. Poll with short queries, or watch the output
> file and touch nothing.

**This did not require C.** The bottleneck was never the language, it was using jsonb as the node
format on the hot path. Byte-level delta application was available in plain SQL as soon as the delta
stopped being a relational operation.

What pgit still does not do that git does: **a packed binary node format**. Deltas now apply as byte
copies, but each resolution still parses jsonb once at the end, and every entry still carries its
column names. That last parse is what caps useful depth around 16. Three
hundred near-identical chunk versions are stored in full. That, not blob separation, is the
remaining gap.

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
