# Storage architecture: matching git's model

Status: **proposal**. Nothing here is built. Every number is measured; see [../PERF.md](../PERF.md).

## Where we are

The packed node format made commits fast — 16.4 s → 1.8 s per commit on a real 1.7M-row dataset —
and made the unpacked store 34% smaller. It also broke `gc`:

| | before packed nodes | after |
| --- | --- | --- |
| `repack` removes | 54–73% | **10%** |
| mean commit, real data | 16,455 ms | **1,801 ms** |
| store before gc | 1,888 MB | **1,243 MB** |

The cause is structural, not a bug. A node is three columns — `keys text[]`, `hashes bytea`,
`entries jsonb` — and `repack` deltas only `entries`. The other two are stored in full for every
version of every node. They are **83% of node bytes** on narrow rows and 30–38% on wide ones, so
after `gc` the store is dominated by data that was never compressed.

Making `repack` delta three columns instead of one would patch this. It would not fix the shape of
the problem, which is worth stating plainly before proposing anything:

**A node is one row in a table.** Each version costs a heap tuple, a TOAST entry, a btree index
entry and a WAL record. Measured on a 200k-row fixture with 22 commits: 20,583 nodes, 27 MB heap,
80 MB TOAST, 1.4 MB index, mean node 4,666 bytes. Git writes objects by appending bytes to a file.

## What git does, and which parts transfer

| git | transfers? |
| --- | --- |
| content addressing, one object per content | already done |
| tree objects so unchanged subtrees are shared | already done, via content-defined chunking |
| **objects concatenated into a packfile** | **no — this is the gap** |
| delta chains within a pack, window 10, depth 50 | partly — deltas exist, but cover one column |
| zlib per object, and the pack compresses as a unit | partly — TOAST compresses per node, not per pack |
| loose objects for new writes, packed later by `gc` | maps exactly onto the current write/`repack` split |

The one thing pgit does not have is the pack: a single value holding many nodes, delta-chained
against each other, compressed as a unit.

That is not a stylistic difference. An earlier experiment already proved the mechanism from the other
direction: storing row images as individual blobs was **1.7× worse** than inline, because each blob
fell below the TOAST threshold and got no compression at all, while a whole chunk compresses as one
unit. Batching for the compressor is exactly why git packs.

## Proposal

### 1. One byte string per node, not three columns

```
node := [count uint32]
        [hashes    count × 32 bytes]      contiguous, key order
        [key_off   count × uint32][key bytes]
        [img_off   count × uint32][image bytes]
```

- the node's own hash is `pgit.hash(substring(rec, 5, count*32))` — one slice, as it is today
- entry *i*'s key and image are two offset reads and a `substring`
- **the whole node is one byte string, so a delta over it covers everything** — which is the property
  the current three-column layout lacks and the reason `gc` collapsed to 10%

Images stay jsonb *inside* the byte string, so `jsonb_populate_record` still materialises rows and
none of the canonicalisation changes.

### 2. Packs: many nodes per row

```sql
pgit.packs      (id bigserial, data bytea)          -- many nodes, delta-chained, one value
pgit.pack_index (hash bytea primary key, pack_id, offset int, length int)
pgit.nodes      (hash bytea primary key, rec bytea) -- loose, written by commits
```

- commits write **loose** nodes, as now, so the write path keeps its current speed
- `gc` rewrites loose nodes into a pack: sort by (level, first key, seq), delta each against the
  previous, concatenate, store as one `bytea`
- reads check `pgit.nodes` first, then `pack_index`

One TOASTed value per pack means one compression unit spanning thousands of nodes, one heap tuple,
one WAL record. This is the change that makes `gc` behave like git's.

### 3. Journal only what blame needs

Write amplification is ~15 µs per changed row, and it is the journal's *content*: two full row images
per change. Profiling put `to_jsonb` at ~5% — the rest is heap, WAL and index maintenance on
`pgit.changes`.

Store the row hash and the changed columns rather than both whole images. `blame` reads a column's
value from the tree at the commit that changed it; the revert guard compares hashes. This is the open
decision already recorded in `BUILD_PLAN.md`, and it is the only lever on the write path.

## What this buys, and what it does not

Expected, with the reasoning:

| | expectation | basis |
| --- | --- | --- |
| storage after `gc` | back to git-like ratios | deltas would cover 100% of node bytes instead of 17% |
| `gc` runtime | much faster | one pass writing a few large values, not 20,000 row updates |
| commit | modest gain | fewer heap/WAL/index writes per node |
| diff | unchanged | already O(difference); the descent is not the cost |
| write path | ~2× better if the journal slims | the images are the cost, measured |

**It will not match git's absolute speed, and the proposal should not pretend otherwise.** Git commits
in 492 ms by hashing a byte stream and appending it. pgit canonicalises every changed row, hashes it,
and writes durably under MVCC with WAL. Postgres will not be talked out of those. A realistic target
is git-comparable *storage ratios* and commits within a small factor — not parity.

The honest framing for the README stays what it is: the scaling property matches git, the constants
do not, and the comparison that matters is against other ways to version a database.

## What would need C, and why we are not doing it

Per-field access into a binary record from SQL means `substring` and `get_byte` calls where jsonb
gets a C-optimised accessor. A C extension would make the node codec fast and unambiguous.

The project rejected C for one reason: distribution. No extension to install is what makes pgit work
unchanged on RDS, Neon and Supabase, and that is worth more than the constant factor. If a build
target ever exists, the node codec is the first and probably only thing worth moving.

## Order of work

Each step is independently valuable and independently verifiable. `bench/quick.sh` runs the whole
shape set in 23 seconds, so each can be measured before the next is started.

1. **Delta the vectors in `repack`.** Smallest change that recovers `gc`. Verifies the diagnosis: if
   effectiveness does not return to 50%+, the analysis above is wrong and the rest should not be
   built. *Checkpoint: `GC=1 bench/quick.sh` returns to >50% off.*
2. **Single byte string per node.** Subsumes step 1 and makes deltas whole-node by construction.
   Touches every consumer of `node_items`, which is now the single accessor — that refactor is
   already done, which is what makes this tractable.
   *Checkpoint: 530 checks green; commit and diff within noise of today.*
3. **Packs.** Adds `pgit.packs`, `pgit.pack_index`, and a `gc` that writes packs.
   *Checkpoint: store after `gc` versus the 10 MB git achieves on the same data.*
4. **Slim the journal.** Independent of 1–3, and the only thing that moves write amplification.
   *Checkpoint: the 10,000-row UPDATE, currently 146–183 ms against a 26–30 ms baseline.*

Steps 1 and 2 are the ones with evidence behind them today. Step 3 is the one that would actually
close the storage gap, and step 4 is the one users would feel on every write.

## The falsification test, run

The proposal stands or falls on one question: does delta'ing the whole node rather than one column
recover `gc`? Measured over 3,000 consecutive node-version pairs from `bench/quick.sh`:

| | size | effectiveness |
| --- | --- | --- |
| unpacked | 15 MB | — |
| today — delta over `entries`, vectors stored whole | 13 MB | **15% off** |
| **delta over the whole node** | **8,147 kB** | **46% off** |

**Confirmed: tripling effectiveness, 15% → 46%.** Steps 1 and 2 are worth building. It does not fully
return to the 54–73% the pre-packed format reached, so the expectation in the table above — "back to
git-like ratios" — is too optimistic and should be read as "roughly half the store, not nine tenths".
Whether packs close the rest is exactly what step 3 would test.

One trap worth recording, because it produced a confident wrong answer first. Measuring the same
thing with the node serialised as a **single** value gave 45 MB — three times *worse* than doing
nothing. That is not a property of whole-node deltas; it is the single-splice degeneration this
project already fixed once. Two changed regions, the hash vector near the front and an image further
back, force one splice to span everything between them. Delta quality depends on the node being
aligned into parts the op list can match — here `[hashes, keys, images]` — and a benchmark that
ignores that measures the wrong thing.

Four separate hypotheses about commit cost were wrong before profiling found the real one, and the
first attempt at *this* measurement was wrong too. Read the plan as something to be tested at each
checkpoint, not as a conclusion.
