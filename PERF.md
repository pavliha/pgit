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

### Versioning a real 2.6 GB dataset

IMDb republishes `title.ratings` every night, so "commit tonight's ratings" is the workload this
exists for rather than a stand-in for it. `bench/realworld_imdb.sh` loads `title.basics` (12.7M rows,
1.9 GB) and `title.ratings` (1.7M rows, 136 MB), then applies 30 nightly updates weighted to popular
titles — about 5,300 scattered rows a night.

| | before | after |
| --- | --- | --- |
| first commit, 14.4M rows | 349 s | 349 s |
| node store after that commit | 1,888 MB against 2,595 MB of data — **0.73×** | |
| mean nightly commit | 45,387 ms | **16,455 ms** |
| diff across all 30 nights, 83,798 rows | 608,562 ms | **37,177 ms** |
| diff of the 12.7M row table nobody touched | ~6 min | **100 ms** |

The diff figures are a controlled A/B: same database, same trees, same 83,798 rows returned, only the
function replaced. The nightly figure excludes the fixture's own scan and update, which are 707 ms a
night — worth measuring separately, because the harness used to charge them to pgit and they turned
out to be 1.5% of the total rather than the explanation.

**Diff was doing two root-to-leaf walks per candidate row.** After 30 nights nearly every chunk
differs, so the descent yields ~3.4M candidate keys to find 83,798 changed rows, and each candidate
cost two tree walks to resolve. The descent already knows every candidate's row hash on both sides,
so a key seen on both sides is decided by comparing them, with no walk at all.

The subtlety that makes this a two-line fix rather than a one-line one: **a key seen on only one side
proves nothing.** The descent skips chunk pairs that are identical, so an unchanged row can be
emitted from side `a` while its counterpart on side `b` lives in a chunk that was never visited.
Treating that as a delete reports rows that never changed, and a contiguous range delete triggers it.
Those keys still need the lookup. The first version of this change did not, passed every existing
diff test, and was caught only by `test/diff_05_descent_oracle.sql` — which computes the same diff by
full-scanning both trees and joining on the key, sharing no code with the descent.

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

## gc was quadratic in the number of node groups

`repack` walks one group of node versions at a time, keyed by level and first key, and selected each
group with `WHERE level = ? AND keys[1] = ?`. `keys[1]` is not indexable, so **every group cost a
sequential scan of the whole node table**: 2,761 groups over 20,583 nodes is 57 million row
examinations on a 200k-row fixture, and at 2 GB `gc` never finished in four attempts.

A partial index on `(level, (keys[1]), seq DESC) WHERE entries IS NOT NULL` turns each group lookup
into an index scan.

| 200k rows, 22 commits | |
| --- | --- |
| `repack` before | 55 s |
| `repack` after | **30 s**, same 58% off |

> [!warning]
> Two of the measurements taken while diagnosing this were wrong, both the same way. `gc` appeared to
> *grow* the store by 11%, twice, which sent me reverting a working change. It had not: live data was
> 6.8 MB of deltas plus 30 MB of unpacked nodes, and the 121 MB reading was bloat `VACUUM FULL` had
> not reclaimed because a benchmark was running concurrently in another database. A clean
> `VACUUM FULL` on an idle machine gave 46 MB — the original figure exactly. This is the third time
> today that concurrent work has corrupted a storage measurement. **Storage numbers are only valid on
> an idle machine.**

## Diff: stop re-walking the tree for images the descent already has

Profiling a diff of 21,076 changed rows, `pg_stat_statements` with nested tracking:

| ms | calls | |
| --- | --- | --- |
| **6,635** | **84,304** | `node_entries` inside `pgit.lookup`'s descent |
| 1,151 | 42,152 | `node_items` inside `lookup`'s leaf read |
| 1,567 | 2,760 | the tree descent itself |

**77% of the diff was point lookups** — two per changed row, each walking the tree — fetching row
images the descent had already produced and thrown away. Carrying them through the same aggregate
that carries the hashes:

| 200k rows, diff across 20 commits | |
| --- | --- |
| re-walking for images | 10,161 ms |
| **images carried through the aggregate** | **1,369 ms — 7.4×** |

This reverses an earlier decision made without measuring it. The images were deliberately *not*
carried, on the reasoning that millions of candidates would spill the hash aggregate — but the cost
of the alternative was never measured, and it was three quarters of the diff.

Two failed attempts preceded this, both worth recording. Skipping images in the descent's internal
levels changed nothing: there are ~50 internal nodes against ~3,000 leaves, so it was never the cost.
And joining the materialised descent back by key produced **duplicate rows**, because the descent can
emit one key from several overlapping chunk pairs — `test/diff_05_descent_oracle.sql` caught it
immediately, which is the third time that oracle has caught a wrong version of this function.

## Whole-node deltas

`repack` used to delta the `entries` column alone. Once a node became three columns, the other two —
`keys` and `hashes` — were stored in full for every version, and they are the *majority* of a node:
78% on the delta fixture, 83% on narrow rows, 30–38% on wide ones. `gc` effectiveness collapsed from
54–73% to **10%**.

It now deltas the whole node, serialised as `[hashes, keys, images]` — three parts so the op list can
align them, rather than one value where a changed hash near the front and a changed image further
back force one splice to span everything between.

| 200k rows, 22 commits | entries-only deltas | whole-node deltas |
| --- | --- | --- |
| node store after `gc` | 97 MB — 10% off | **46 MB — 58% off** |
| `repack` runtime | 171 s | **55 s** |
| commit, 100 adjacent / 2,000 scattered | 13 ms / 394 ms | 13 ms / 394 ms |

On the delta test fixture: 1,381 kB → 506 kB, with a mean delta of **228 bytes against a 3,627 byte
node**.

Two things this cost, both worth recording. The parts must be embedded as jsonb, not as text: putting
the images in as `entries::text` escapes every quote in every row image and inflates exactly the
payload the delta has to carry. And `node_cols`, which resolves a node through its delta chain, must
not be called for nodes that are not packed — putting it on the unconditional read path made the test
suite time out, because every node access became a PL/pgSQL call. A `CASE` short-circuits it so only
packed nodes pay.

## The packed node format

A node used to be a jsonb array of `{k, h, v}`. It is now three columns: `keys text[]`, `hashes
bytea` — the child hashes packed at a 32 byte stride, in key order — and `entries jsonb` holding
only the row images. `hashes` is exactly the pre-image of the node's own hash, so `pgit.hash(hashes)`
is the node hash and every existing hash value is unchanged.

That makes the operations that dominated a commit into whole-value C calls rather than one SQL row
per entry: `array_position` finds an entry, `overlay` replaces its 32 bytes, `jsonb_set` replaces its
image, and rehashing is a single `pgit.hash`.

| 1.7M rows | jsonb nodes | packed nodes |
| --- | --- | --- |
| first commit (full build) | 15,223 ms | **12,060 ms** |
| 500 scattered rows | 1,381 ms | **336 ms** |
| 5,000 scattered rows | 4,049 ms | **1,596 ms** |
| node store | 209 MB | **120 MB** |

**It is smaller as well as faster**, which was not obvious in advance: an entry used to carry its hash
as 64 hex characters and its key as a jsonb string, and the packed vectors replace both at 32 raw
bytes plus one array element. An intermediate version that added the vectors *alongside* the existing
jsonb was 47% larger — the win only appears once the duplication is removed.

Against where this work started, a 5,000 row scattered commit has gone **13,383 ms → 1,596 ms, 8.4×**,
and the gap to git on the same workload from 27× to about 3×.

Two consequences worth recording. `repack` groups node versions by their first key, which used to be
read out of the entries array and is now `keys[1]`. And `make_delta` used to align entries by their
`k` field; with images-only entries it aligns by position instead, which is exact for two versions of
a chunk whose membership has not changed, and degrades to a larger delta — never a wrong one, since
every delta is verified against its target — when it has. Missing the second of those made deltas
18× larger than the nodes they replaced, and the existing delta tests caught it.

## Profiling the commit path, and what it says about the binary node format

`pg_stat_statements` with `track = all`, one commit of 5,000 scattered rows in a 1.7M row table.
Every earlier guess about this was wrong — sha256, the canonical expressions, triple evaluation of
`canon_numeric`, PL/pgSQL set-returning functions and row-image fetching were each measured and each
eliminated. What the profile actually found:

| finding | effect |
| --- | --- |
| the splice widened the touched region by one chunk either side | 11,308 chunks rebuilt to change 5,000 rows |
| `pgit.setting('chunk_target')` read per row | 872,204 queries in one commit, for a constant |
| the canonical row expression rebuilt from the catalogue per region | 10,073 calls |

Boundaries are `is_boundary(key)`, so only an inserted or deleted key can move one — the widening is
unnecessary for pure updates. Removing it and hoisting the chunk target:

| | |
| --- | --- |
| 5,000 scattered rows, at the start of this work | 13,383 ms |
| after the sparse rebuild path | 9,291 ms |
| after dropping the widening | 4,743 ms |
| **measured again on a clean fixture** | **4,049 ms — 3.3× faster** |
| full rebuild of 1.7M rows, chunk target hoisted | 17,665 → 15,223 ms |

**What is left, and the honest ceiling.** 4,023 ms of the remaining 4,743 is a single statement that
expands every entry of every touched chunk and re-aggregates it. That is the packed binary node
format this document has listed as the outstanding gap. Measured on a real leaf — 674 entries,
59 kB of jsonb — over 5,000 rebuilds:

| | |
| --- | --- |
| expand + re-aggregate, plus hashing from the expansion | 3,912 ms |
| `array_position` + `overlay` the hash + `jsonb_set` the entry | **1,537 ms** |

So the binary format is worth about **2.5× on that statement, and roughly 2× on the commit** — not
the order of magnitude it might promise. The floor is memcpy: rebuilding a 59 kB node to change one
row copies 59 kB whatever the encoding, and 5,000 touched chunks is ~300 MB of copying per commit.

**Smaller chunks do not help, re-confirmed after the algorithm changed.** Node size drives the
copying, so a smaller target looks like the obvious answer. It is not, and the earlier finding still
holds: at 1.7M rows, a 5,000 row scattered commit costs 4,049 ms at target 64, 4,448 ms at 32 and
5,462 ms at 16, with the node store growing from 209 MB to 241 MB. More, smaller nodes cost more
tree levels and more nodes to write than they save in bytes copied.

## Where pgit beats git, and where it does not

The comparison below this one used a 28 MB file, which flatters git: its commit cost is O(file), so a
small fixture hides it. The same 12.7M-row IMDb data at full size, same 100-row change:

| | git | pgit |
| --- | --- | --- |
| 12.7M rows as a 1.0 GB TSV / a tracked table | | |
| baseline commit | 10,817 ms | 253,868 ms |
| **100 changed rows** | **12,062 ms** | **527 ms — 22.9× faster** |
| 28 MB slice, ~5,300 changed rows | **492 ms** | 1,801 ms |

**git re-hashes and re-compresses the whole file on every commit**; pgit rewrites only the chunks
holding changed rows. The crossover is around 50 MB. Below it git wins on constants, above it pgit
wins on complexity and the gap grows linearly with the data.

git still wins the first commit outright — 10.8 s against 254 s — because a full tree build
canonicalises and hashes every row individually where git makes one pass over a byte stream. That is
a one-time cost, but it is real and it is 23×.

## Measured against git, on the same data

The claim "git's diff performance" was in the README for weeks. It is wrong, and this is by how much.
The same 1.7M row IMDb ratings table, 30 commits, each changing ~5,300 scattered rows: as a TSV in a
git repository, and as a tracked table in pgit. Identical change sets — git saw 152,349 modified
rows, pgit 152,068.

| | git | pgit | |
| --- | --- | --- | --- |
| baseline commit | **389 ms** | 17,259 ms | 44× |
| mean commit over 30 | **492 ms** | 13,383 ms | 27× |
| diff across all 30 commits | **391 ms** | 60,940 ms | **156×** |
| store, loose | 316 MB | 1,742 MB | |
| store, after gc | **10 MB** | — | |
| gc | 11 s | 33 min (killed) | |

Git's diff is a linear Myers diff over two sorted 28 MB text blobs; its commit is a hash and a zlib
pass over the same. pgit canonicalises every changed row (`normalize`, `trim_scale`, sha256 each),
computes content-defined boundaries, builds jsonb nodes, and writes them to a heap with WAL and
index maintenance. That is not a constant factor away from a byte-stream hash and it will not close.

**What does hold is the scaling property the design was chosen for.** Diff cost tracks the size of
the difference, not the history between two commits: 10 rows 10,000 commits apart costs 163 ms, the
same as one commit apart. Git has that property and so does pgit. The shape matches; the constant
is about 100× worse.

**One structural axis favours pgit, and this fixture hides it.** Git's per-commit cost is O(file):
changing 5,300 rows in a 28 MB TSV re-hashes and re-compresses all 28 MB. pgit's is O(changed
chunks). At 28 MB git's whole-file cost is an invisible 492 ms; on the full 2.6 GB IMDb set the same
commit would re-process 2.6 GB, while pgit's untouched 12.7M row table costs **100 ms**. A fair
comparison at that scale has not been run, so this is stated as a structural difference rather than
a measurement.

And the part git does not do at all: the pgit copy is a live database — indexed, constrained,
transactional, queryable — throughout. The git copy is a file you must materialise to use.

## What tracking a table actually costs

Re-measured after the commit and diff work, on a 1M-row table with four columns.

| | untracked | tracked | |
| --- | --- | --- | --- |
| `SELECT` scan + range scan | 26–31 ms | 26–29 ms | **free, within noise over 3 runs** |
| `UPDATE` 10,000 rows | 26–30 ms | 146–183 ms | |
| `INSERT` 10,000 rows | 6 ms | 91 ms | |
| `DELETE` 10,000 rows | — | 100 ms | |
| journal storage | — | **296 bytes per changed row** | before and after images |

**Reads are unaffected**, which had been argued from structure and is now measured: pgit's triggers
are write-side and the data never moves. It does add one expression index to the tracked table for
canonical key lookups, which costs on the write path and in storage.

**The write multiplier is not a stable number, and quoting one is misleading.** The tracked cost is
steady at roughly **15 µs per changed row**; what moves is the baseline it is compared against. The
same 10,000-row `UPDATE` measured 15 ms on freshly loaded pages and 26–30 ms once those rows had
been updated before, so the same absolute overhead reads as anywhere from **5× to 12×**. The 10.1×
below is one baseline, not a constant. Per changed row is the figure to design against.

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
