# Build plan

How this was built, and what it cost. One item per iteration: implement in `sql/`, add pgTAP tests
in `test/`, run `make test` until green, then tick the box and append a line to **Progress log**.

The progress log is the useful part. It records the bugs that got through, how each was found, and
the ones a green test suite failed to catch — including several where the test itself was the bug.

## Decisions taken (reversible)

| Decision | Taken | Why |
| --- | --- | --- |
| Identity across branches | canonical PK bytes; branch-created rows get disjoint sequence ranges | works with existing serial PKs, no schema migration forced on adopters |
| Materialisation | logical — one working database holds one checked-out branch | the only form a plugin can do; matches git's working tree |
| Staging model | auto-commit per transaction, explicit grouping opt-in later | matches how an application writes; a psql user can opt in |
| Hash | `sha256` from core | no pgcrypto dependency |
| Chunk target | 64 | measured within 4× across sequential, uuidv4, uuidv7 and common-prefix keys |
| License | MIT | swap before any public release if a patent grant is wanted |
| Dirtiness | decided by **content** (live tree root vs HEAD's recorded root), not by unstamped journal rows | grove's journal is ENABLE ALWAYS, so checkout's own writes would make the tree look dirty the instant it finished. Content is also more faithful to git: edit a value and put it back and you are clean. |
| Checkout journal rows | `checkout` deletes its own unstamped journal rows | a checkout is a *materialisation*, not an edit. A revert produces new content that should become a commit; a checkout reproduces a commit that already exists. |
| DDL detection | **catalogue fingerprint at commit time**, no event trigger | an event trigger needs superuser and buys nothing for correctness here — the fingerprint recorded per commit is what every guard actually reads. This is the AC-PORT-04 fallback promoted to being the mechanism, so the portable path is the only path. |
| Merge runs with triggers ON | merge does **not** use replica mode, unlike revert and checkout | replica mode disables referential-integrity triggers, which would defeat the entire point of AC-MERGE-08. A merge is a real write to the working tree, so constraints and user triggers behave exactly as they would for any other write. |
| AC-REPLAY-02 reading | a *read* must not grow history; a revert is a real write and IS journalled | the criterion says "replay does not record new journal entries. History must not grow by being re-read" — the second sentence is the intent. If replay went unjournalled, `diff_journal` would disagree with the tree for any range containing a revert. **Reversible: say the word and replay becomes invisible to the journal.** |

## Done

- [x] **canon** — canonical row form, content-defined boundaries, tree root. 34 assertions green.
      AC-CANON-01 through -07.
- [x] **journal** — `grove.changes`, `grove.tracked`, one generic row trigger, `grove.track` /
      `grove.untrack`, actor and source from `SET LOCAL grove.actor` / `grove.source`, and a
      `BEFORE TRUNCATE` statement trigger that journals every destroyed row. 21 assertions.
      AC-COMMIT-01, -03, -07, AC-DDL-05, -06.
- [x] **objects** — `grove.nodes`, `grove.trees`, `grove.write_tree` persisting every level
      content-addressed. `tree_root` now delegates to it, so there is one hashing implementation.
      8 assertions.
- [x] **commit** — `grove.commits` DAG, `grove.refs`, `grove.head`/`grove.resolve`,
      `grove.commit(msg, who, ts)`, and `grove.advance_ref` as a compare-and-swap. 15 assertions.
      AC-COMMIT-02, -05, -06, AC-REF-01.
- [x] **diff-core** — `grove.leaves`, `grove.diff_leaves` (pruning descent), `grove.diff_tree`,
      `grove.diff(a_sha, b_sha)`, and `grove.apply_diff` for the round trip. 14 assertions.
      AC-DIFF-01, -02, -03.
- [x] **diff-oracle** — `grove.changes.commit_sha` stamped at commit, `grove.ancestry`,
      `grove.diff_journal` (independent replay implementation), `grove.lookup` point lookup, and a
      randomised differential test: 1000 operations, 51 commits, 40 sampled commit pairs.
      5 assertions. AC-DIFF-04. **Found three real bugs in the tree diff.**
- [x] **diff-surface** — `diff_stat`, `diff_numstat`, `diff_shortstat`, `diff_name_only`,
      `diff_name_status`, and a `pathspec` argument on `grove.diff` addressing table, row
      (`t1:5`) and column (`t1.name`). 14 assertions. AC-DIFF-06, -07.
- [x] **revert** — `grove.revert(sha)` with a per-row conflict guard, replay under
      `session_replication_role = replica`, and `grove.live_hash`. 14 assertions.
      AC-REPLAY-01 through -05.
- [x] **blame** — `grove.blame(tbl, key)` returning the last writer, actor, timestamp and current
      value per column, from the journal. 8 assertions. AC-BLAME-01, -02.
- [x] **log-show** — `grove.log(start, pathspec)` walking the DAG by depth, `grove.show(sha)`,
      `grove.short_sha`. 10 assertions. AC-LOG-01, -02, AC-SHOW-01.
- [x] **branch** — `grove.branch`, `grove.branches`, `grove.checkout`, `grove.delete_branch`,
      `grove.is_dirty`. 13 assertions. AC-REF-02, -03, -04.
- [x] **merge** — `grove.ancestors`, `grove.merge_base` (refusing criss-cross), `grove.merge_plan`
      (three-way per cell), `grove.apply_row`, `grove.conflicts`, `grove.merge` with fast-forward and
      two-parent merge commits. 23 assertions across four files.
      **AC-MERGE-07 and -08 both pass — the central architectural argument is proven.**
- [x] **replay-verbs** — `grove.cherry_pick`, `grove.rebase`, `grove.rebase_abort`,
      `grove.materialise`, `grove.record_conflicts`, `grove.rebase_state`. 16 assertions across three
      files. AC-REPLAY-06 through -09.
- [x] **perf-1m** — `bench/` fixture, commit and diff harnesses, `make bench`, results in
      `PERF.md`. No pgTAP assertions: timing assertions are flaky and would be worse than no test.
      **AC-PERF-01 property holds, AC-PERF-04 and -05 miss; both gaps recorded, neither target
      touched.**
- [x] **ddl** — `grove.schemas`, `schema_fingerprint`, `schema_columns`, `record_schemas`,
      `assert_same_schema` guarding cherry-pick and merge. 9 assertions.
      AC-DDL-01, -02, -04, AC-REPLAY-10, AC-MERGE-12.
- [x] **cli** — `bin/grove`, a bash-over-psql CLI: status, log, show, diff (with --stat, --numstat,
      --shortstat, --name-only, --name-status, --exit-code), blame, branch, checkout, commit,
      merge, rebase, cherry-pick, revert, track. 15 checks in `test/cli_test.sh`.
      AC-CLI-01 through -04.
- [x] **incremental tree maintenance (leaf level)** — `write_tree_incremental`, `changed_keys`,
      `leaf_list`, `build_up`, `row_hashes_range`, a canonical-key expression index created at
      track time, and `snapshot_trees` feeding commit, merge and cherry-pick. 4 assertions.
      **Commit of 10 rows: 15,852 ms → 394 ms.**
- [x] **incremental upper levels** — the splice now happens at **level 1** (~244 nodes at 1M rather
      than 15,600 leaves), with `nodes_at_level` and `build_one_level`. 3 more assertions, including
      a three-level-deep fuzz. **Commit of 10 rows: 394 ms → 25 ms. AC-PERF-02 and AC-PERF-04 now
      pass at 1M.**
- [x] **reuse temp tables across calls** — `grove.ensure_scratch` creates nine scratch tables once
      per session; every tree function now `TRUNCATE`s and refills them instead of
      `DROP`/`CREATE`. 3 assertions. **500 commits in one transaction: crashed → 16 ms mean.**
- [x] **AC-PERF-03** — 50-table fixture, diff locality measured by block counts. 5 assertions.
      **494 blocks for one changed table against 24,700 for fifty — a ratio of exactly 50.0.**
- [x] **statement-level journal trigger** — `grove.journal_stmt` with `REFERENCING OLD TABLE`/`NEW
      TABLE`, three statement triggers per tracked table. 6 assertions.
      **Write amplification 15× → 10.1×. AC-PERF-05 still misses its 2× target; see `PERF.md`.**
- [x] **AC-REPLAY-11** — `test/kill_test.sh`, a two-session harness that kills a backend mid-rebase.
      9 checks, wired into `make test`.
- [x] **AC-PERF-02 at the full 10,000 commits** — **163 ms for 10 rows 10,000 commits apart, against
      179 ms one commit apart.** Criterion met at the stated figure, not a reduced one.
- [x] **checkout across a schema change** — `grove.assert_live_schema` runs before the dirty check
      and names the table and both column lists. 5 assertions.

**Every item in the original plan is done.** What follows was raised by measurement.

## Next

**Nothing outstanding.** Every planned item, every item raised by measurement, and every gap this
plan recorded as uncovered is done. What remains is under **Blocked** — two product decisions, not
engineering.

## Blocked

- **AC-PERF-05 needs a decision, not more code.** Write amplification is 10.1× against a 2× target,
  and the remaining cost is the journal's *content*: two jsonb images per changed row. Profiling
  shows `to_jsonb` is only ~5% of it — the rest is heap writes, WAL and index maintenance on
  `grove.changes`, which no amount of optimisation avoids. Options: (a) drop the `before` image and
  have `blame` and the revert guard read it from the parent tree, (b) journal only changed columns,
  or (c) decide 2× was the wrong number for a journal that stores full row images.
  **Not moving the target unilaterally.**
- **Storage retention needs a decision — but the premise it was written on was wrong.** This item
  used to read "540 MB against a 107 MB table, none of it collectable". That was a **pre-`gc`**
  number. Measured properly at 1M rows and 10,000 commits: 487 MB unpacked, **197 MB (1.8×) after
  `gc` at the default depth**, 131 MB (1.2×) at depth 50, and the curve is flat past that — the
  residual is one full snapshot, which is the floor. Delta compression already solved the storage
  problem; see `PERF.md`.
  What is left is the actual policy question, unchanged by any of this: **how much history should a
  database keep, and who decides?** `prune --before` exists and works. Nobody has chosen a default.
  Two things were measured and both killed the obvious fixes. **Separating blobs from trees,
  git-style, makes it 1.7× worse** — chunk-level compression beats per-row storage, because pglz
  compresses a whole chunk as one unit while individual row blobs fall below the TOAST threshold.
  And **`chunk_target=16` is worse than 64 at 1M rows** (6× slower commits, 27% more storage),
  inverting a 20k-row result that suggested otherwise.
  **Delta compression is now built** (`grove.repack`, default depth 1: 34% of the node store for 11%
  read cost — see `PERF.md` for the full depth curve). What remains: auto-tune `chunk_target` from
  table size, add a retention policy, or make deep delta chains affordable with a compact binary node
  encoding so deltas apply as byte copies rather than jsonb rebuilds.

## Follow-ups raised while building

- **FK enforcement is off during replay.** `session_replication_role = replica` disables referential
  integrity triggers as well as user triggers. A whole-commit revert is safe *by construction* — it
  restores a state that was already committed and valid, and the tests assert that by root hash. But
  a future **partial** revert (pathspec-scoped, restoring some rows and not others) could leave a
  dangling reference undetected. Before shipping partial revert, either re-validate the touched
  constraints afterwards or use `ALTER TABLE … DISABLE TRIGGER USER`, which suppresses only user
  triggers and leaves RI active (at the cost of an ACCESS EXCLUSIVE lock).
- **Checkout across a schema change still only refuses politely.** `grove.assert_live_schema` now
  names the table and both column lists instead of blaming uncommitted changes, but `checkout` still
  materialises data and not shape. Actually versioning DDL and replaying it on checkout is a project,
  not an afternoon, and remains undone.
- **The conflict guard is O(table) per revert.** `grove.live_hash` computes `row_hashes` over the whole
  table for each key it checks. Correct but wasteful; it should become a keyed lookup before the
  perf gates.
- **Git verbs deliberately not built, with the reason.** The inventory is now closed except these,
  and each is a judgement rather than a backlog item.
  - **`subtree`, `submodule`** — no analogue. Both compose *repositories*; there is one database and
    one history here, and a nested history would be a second `grove` schema with its own refs, which is
    just two databases and a bundle.
  - **Signed commits** — needs key management, a trust model and a verification story that none of the
    rest of this has. Real work, not a missing function.
  - **`filter-branch`** — rewrites every commit after a point. `prune` already truncates history; the
    remaining use (scrubbing a column out of the past) means recomputing every tree from the rewrite
    point forward, and offering that without a tested rollback would be irresponsible.

## Progress log

Newest last. One line per completed item: what was built, assertion count, anything surprising.

- **canon** — canonical form + content-defined chunking + tree root. 34/34 assertions green on
  first run. Surprise: none of the type traps needed a second attempt; `normalize(…, NFC)`,
  `trim_scale` and `sha256` are all in core on PG18, so the layer has zero extension dependencies.
- **journal** — 21 assertions, suite now 55/55. `BEFORE TRUNCATE` can still read the table, so
  truncate journals all 500 rows as real DELETEs and stays revertible — AC-COMMIT-07 is satisfied
  properly rather than by recording a bare "truncated" marker. Two traps: a plpgsql parameter
  named `tbl` is ambiguous against `grove.tracked.tbl`, and `CREATE OR REPLACE FUNCTION` cannot
  rename a parameter, so renaming it needs an explicit `DROP FUNCTION IF EXISTS` to keep
  `install.sql` re-runnable. Any later signature change needs the same treatment.
- **objects** — 8 assertions, suite now 63/63. The headline measurement: changing **one row** in a
  5000-row table rewrites **exactly one** leaf node and shares every other one. That is the
  O(difference) property demonstrated rather than asserted, and it is the first real evidence the
  storage bet works. `write_tree` now always wraps leaves in a node (the old `tree_root` returned
  a bare row hash for single-row tables, which left the root with no node to descend), and
  `tree_root` delegates to `write_tree` so the two can never drift apart.
- **commit** — 15 assertions, suite now 78/78. `grove.commit(...)` is callable unquoted; COMMIT is
  a non-reserved keyword, so the git-shaped name survives. Naming parameters `msg`/`who`/`ts`
  rather than `message`/`author`/`at` avoided the shadowing trap from the journal item — apply
  that rule to every future function. The real observation is AC-COMMIT-02: commits, tree nodes
  and the ref all roll back together with a plain `ROLLBACK TO SAVEPOINT`, because every one of
  them is an ordinary table write. A from-scratch engine has to build its own crash-safety for the
  object store; here transactionality over history is simply inherited.
- **diff-core** — 14 assertions, suite now 92/92 **verified from a completely empty database**.
  The master property holds: `apply(diff(A,B), A)` produces B by root hash, including across 20
  commits of history — and a row updated 20 times across those 20 commits is reported as exactly
  **one** change. Design change forced here: leaf entries now carry the row image (`v`) as well as
  its hash, because a diff cannot emit before/after images from hashes alone, and checkout will
  need them too. Node hashes are still computed from row hashes only, so every canon root is
  unchanged. The descent gathers leaves from differing subtrees on *both* sides and joins by key,
  rather than joining children by exact key at each level — otherwise deleting a chunk's boundary
  key reshapes the chunk and the whole region reads as deleted-plus-added.
- **diff-oracle** — 5 assertions, suite now 97/97, verified from an empty database. This tick paid
  for the whole testing strategy: the differential test **failed on its first run and exposed three
  independent bugs in the tree diff**, none of which the twenty hand-written diff assertions caught.
  (1) Internal children were paired by exact key, so deleting a chunk's boundary key reshaped the
  chunk and the region read as deleted-plus-added — children must be paired by **key range**.
  (2) Trees of **different heights** (row count crossing a chunking threshold) were compared level
  against level, producing garbage; that pair now falls back to a full leaf gather.
  (3) The real one: descent alone cannot decide anything. When an A-child overlaps two B-children
  and only one differs, descending that pair emits all of the A-child's leaves, but the unchanged
  rows' B-side copies live in the *other* B-child that was correctly skipped as equal — so they
  read as deletes. **The descent is only a candidate finder; every candidate key must then be
  resolved by point lookup in both trees.** That is what `grove.lookup` is for, and it is the
  correct shape: O(candidates × depth) rather than O(table).
  Method note for the next tick: the first two fixes were guesses made without re-measuring, and
  both were wrong about the real cause. What actually worked was comparing three implementations —
  descent, a full leaf-set comparison as tree ground truth, and the journal — which located the
  faulty one in a single query. Measure, do not guess.
- **diff-surface** — 14 assertions, suite now 111/111 from an empty database, green on the first
  run. The one real decision: for a **column pathspec**, is an inserted row whose column is NULL a
  change to that column? Comparing raw jsonb says yes (SQL NULL on the missing side vs jsonb
  `null`), which is wrong — asking for `t1.note` when `note` was never touched should report
  nothing. Both sides are now normalised through `COALESCE(… , 'null'::jsonb)`, so a column
  pathspec reports a row only when that column's value genuinely differs. A row pathspec against a
  composite primary key raises rather than silently matching nothing, which is the AC-CLI-02
  principle applied one layer down: refuse loudly, never answer quietly wrong.
- **revert** — 14 assertions, suite now 125/125 from an empty database, green on the first run.
  The find of the tick is **`ALTER TABLE … ENABLE ALWAYS TRIGGER`**. Replaying under
  `session_replication_role = replica` suppresses user triggers — proven by a side-effect table that
  stays empty while a revert rewrites 3 rows — but it would equally silence grove's own journal and
  leave history blind exactly when the database is being rewritten. Marking `grove_journal` as
  ALWAYS makes it fire in replica mode while everything else stays quiet. That is the precise
  behaviour the design wanted and it is one `ALTER TABLE` away in stock Postgres.
  Also worth stating plainly: replica mode disables **foreign-key enforcement** too. A whole-commit
  revert is still safe by construction, because it restores a state that was already committed and
  valid — the cascade test proves it by root hash and then re-checks every FK by hand. Partial
  reverts would not have that guarantee; noted under Follow-ups rather than discovered later.
- **blame** — 8 assertions, suite now 133/133 from an empty database, green on the first run. One
  decision worth knowing: an INSERT attributes **every** column of the new row, not just the
  non-NULL ones. Without that special case a column that has always been NULL would be blamed on
  nobody, because the "did this column change" test normalises both sides through
  `COALESCE(…, 'null'::jsonb)` and a NULL insert looks identical on both sides. Git blames every
  line of a new file to the commit that added it; this matches. The other property worth stating:
  setting a column back to an earlier value blames the **latest writer**, not the value's original
  author — tested explicitly, because the opposite behaviour would look plausible in a demo and be
  wrong.
- **log-show** — 10 assertions, suite now 143/143 from an empty database, green on the first run
  and the cheapest tick so far: `log -- <pathspec>` and `show` are both thin wrappers over the diff
  built two ticks ago, so the entire surface came almost free. One semantic worth stating because
  it is easy to get wrong: the **root commit touches everything**. `diff(NULL, root)` reports every
  row as an INSERT, which is what makes `log -- t2` correctly include the commit that created `t2`
  rather than starting the history at the first modification.
- **branch** — 13 assertions, suite now 156/156 from an empty database. The measurement that
  matters: checking out a branch that differs by **3 rows in a 200 row table writes exactly 3
  rows** — AC-REF-03 verified by counting writes rather than by wall clock, so it cannot be
  fooled by a fast machine. Two decisions fell out of building it, both in the table above:
  dirtiness had to become **content-based**, because grove's own ENABLE ALWAYS journal would
  otherwise make the tree look dirty the moment a checkout finished; and `checkout` now deletes
  its own unstamped journal rows, since materialising an existing commit is not an edit.
  The runner also earned its keep again — it flagged the file as INCOMPLETE at 13 assertions
  against a declared plan of 12, catching a miscount that would otherwise have quietly
  under-reported coverage.
- **merge** — 23 assertions across four files, suite now 179/179 from an empty database.
  **Both gates pass, and they prove the interesting thing rather than the easy thing.** In
  AC-MERGE-07 two branches insert *different* primary keys carrying the *same* unique email:
  `merge_plan` reports **zero conflicts** and exactly one clean upsert, so a naive implementation
  would apply it and corrupt the table — and Postgres aborts it on the unique index. AC-MERGE-08 is
  the same shape across two tables: main deletes a category, the feature branch adds a product
  referencing it, no cell conflicts exist, and the foreign key stops it. Both tests assert the
  zero-conflict plan *first*, so they can never pass for the trivial reason.
  That is the deferred-constraints claim from the design demonstrated end to end: constraint
  validation for merges costs one `SET CONSTRAINTS` pair, where a from-scratch engine has to
  reimplement it. The corresponding decision is in the table above — merge deliberately does **not**
  run in replica mode, because that would disable the very enforcement being relied on.
  Also working: cell-level merge (two branches editing different columns of one row merge cleanly),
  identical edits on both sides are not a conflict, delete-versus-modify is a row-level conflict,
  conflicts land in a queryable table with all three sides, fast-forward, and two-parent merge
  commits. One trap: `merge_base` was marked STABLE while creating a temp table, which Postgres
  rejects only at call time — rewritten as CTEs.
- **replay-verbs** — 16 assertions across three files, suite now 195/195 from an empty database.
  The design paid off exactly as predicted two ticks ago: **cherry-pick is just a three-way merge**
  with base = the picked commit's parent, ours = HEAD, theirs = the picked commit, so it reuses
  `merge_plan` and `apply_row` untouched. **Rebase is then a loop of cherry-picks** onto the target,
  and it inherits conflict detection for free. Neither verb needed new merge logic, which is why
  DoltgreSQL lacking both is a gap rather than a hard problem.
  `rebase` records resumable state, stops at the first conflicting commit, and `rebase_abort`
  restores the pre-rebase ref *and* content exactly.
  Two traps, both self-inflicted and both already written down: a plpgsql variable named `branch`
  shadowed `rebase_state.branch` — the identical mistake to the `tbl` one from the journal tick, so
  the rule now needs applying to **local variables**, not just parameters. And dropping a temp table
  from inside the `FOR` loop iterating over it fails with "used by active queries"; the drop belongs
  at the top of the function, not the bottom.
  Honest gap: AC-REPLAY-10 (replaying across a schema change) and AC-REPLAY-11 (backend killed
  mid-replay) are **not** covered — the first belongs with the ddl item, the second needs a second
  session. Listed under Follow-ups rather than counted as done. all worth remembering.
  (1) Appending a redefinition instead of replacing the original left two definitions of
  `row_hashes` in one file, and the second install died on "cannot change return type".
  (2) SQL-language functions validate their body at `CREATE` time, so a forward reference fails on
  a fresh database while working fine on an incremental install — only plpgsql can forward-
  reference. (3) The `DROP FUNCTION` lines stayed below the new `CREATE`, dropping the function
  after creating it. **Every function belongs exactly once, in dependency order, with its drops
  immediately above it — and only a `down -v` rebuild proves it.**
- **tooling** — `test/run.sh` was under-reporting: a file that aborted mid-way still printed a
  green total, because it only counted `ok` lines. It now parses each file's `1..N` plan and fails
  the suite when fewer assertions ran than were planned. Worth knowing that the first version of
  the harness would have hidden exactly the kind of failure this project must not hide.
- **perf-1m** — no new assertions; the deliverable is `bench/` and `PERF.md`. **The read side works
  and the write side did not, both structurally.** Diffing 10 changed rows of a million took 189 ms
  and 1000 took 451 ms — 100× the changes for 2.4× the time, the O(difference) property holding on
  real data. Commit was **flat**: 15,852 ms for ten rows, 16,846 for a thousand, because
  `write_tree` rebuilt the whole tree every time. Write amplification 15.6×. No target was moved.
- **ddl** — 9 assertions. Every commit records the **shape** of each tracked table, and
  `assert_same_schema` guards cherry-pick and merge (AC-REPLAY-10, AC-MERGE-12). Decision: **no
  event trigger** — it needs superuser and buys nothing, since the fingerprint recorded at commit is
  what every guard reads, so the AC-PORT-04 fallback became the only path. AC-DDL-01 measured:
  `ADD COLUMN` on 1M rows costs 20.0 s and doubles node storage, because the new tree shares nothing.
  Test-authoring trap: the first AC-MERGE-12 attempt failed because merging an *ancestor* returns
  early before reaching the guard — the code was right and the test was wrong.
- **cli** — 15 checks, green first run. Bash over psql, no build step. AC-CLI-02 took the design
  work: every command declares its allowed flags and anything else exits **129 naming the flag**, so
  an unimplemented git flag can never be silently ignored.
- **incremental tree maintenance (leaf level)** — 4 assertions. **Commit of 10 rows: 15,852 ms →
  394 ms.** Built test-first against the only property that matters: over 30 rounds of random
  operations plus a bulk delete and an append, the incrementally maintained root must equal the full
  rebuild's root, checked by hash every round. The subtlety is chunk boundaries — deleting a boundary
  key merges chunks and inserting one splits them, so the rebuilt region is **widened by one chunk
  each side**. Three Postgres lessons: index expressions must be IMMUTABLE; a data-modifying CTE
  cannot sit inside an `INSERT`'s source; and a temp table dropped and recreated in one function
  invalidates cached plans in another.
- **incremental upper levels** — 3 assertions. **Commit of 10 rows: 394 ms → 25 ms; 1000 rows:
  3,241 ms → 135 ms.** AC-PERF-04 passes at 1M and AC-PERF-02 passes outright. The shortcut: splice
  at **level 1** (~244 nodes at 1M, not 15,600 leaves) and build up from there.
  **The lesson was self-inflicted.** I had wrapped index creation in `EXCEPTION WHEN others THEN
  RAISE NOTICE`, and because `convert_to` is STABLE the index **never got created on any table** for
  a whole tick — every range read was a sequential scan. A swallowed exception turned total failure
  into a filtered-out notice. Fixing it (index the canonical text with `COLLATE "C"`) took the
  10-row commit from 310 ms to 25 ms on its own.
- **reuse temp tables** — 3 assertions. **500 commits in one transaction: crashed on
  `max_locks_per_transaction` → 16 ms mean per commit.** The keeper is `DELETE` versus `TRUNCATE`:
  the first version used `DELETE FROM` and individual commits regressed **24×** (23 → 598 ms) while
  every test stayed green, because the initial full build leaves a million dead tuples in the scratch
  table and no autovacuum runs mid-transaction. **A correctness fix that silently costs 24× is only
  visible if the benchmark is re-run.**
- **AC-PERF-03** — 5 assertions, measured by **block counts rather than wall clock** using
  `pg_stat_get_xact_blocks_fetched`, whose `_xact_` variants are visible inside the running
  transaction. Across 50 tables, `diff --stat` fetches **494 blocks** when one table changed and
  **24,700** when all fifty did — a ratio of exactly **50.0**.
- **statement-level journal trigger** — 6 assertions. **19× → 10.1×.** Three `FOR EACH STATEMENT`
  triggers with transition tables. The semantic worth pinning: matching old to new rows requires
  joining the transition tables **on the primary key**, so an update that *changes* a primary key is
  recorded as a **DELETE plus an INSERT** — correct, because the key is row identity.
- **AC-REPLAY-11** — 9 checks in a two-session shell harness that kills a backend mid-rebase. Be
  precise about what it proves: the criterion says "releases its **advisory** locks" and **grove takes
  no advisory locks anywhere**, so that half is vacuous, not passed. What it does show is that crash
  safety is **inherited** — every ref move, node write and journal row is an ordinary table write in
  the caller's transaction.
- **AC-PERF-02 in full** — **163 ms for 10 rows 10,000 commits apart, against 179 ms one commit
  apart.** Flat in history at the stated figure. The run also produced the most uncomfortable number
  in the project: 10,000 commits grew `grove.nodes` to **540 MB for a 107 MB table**, none of it
  garbage. See Blocked.
- **checkout across a schema change** — 5 assertions. `assert_live_schema` runs before the dirty
  check and names the table and both column lists. Previously it failed with "uncommitted changes",
  which was true but useless. **A misleading error is worse than a blunt one: it sends you looking
  for changes you never made.** Three of the five assertions check the *wording*, because the wording
  is the whole fix.
- **storage investigation** — no code change; two hypotheses measured and both killed. Separating
  blobs from trees git-style is **1.7× worse** (13 MB vs 7,784 kB), because chunk-level compression
  beats per-row storage. And `chunk_target=16`, which looked like a 29% storage win at 20k rows, is
  **worse on both axes at 1M** — 6× slower commits and 27% more storage. **Twice wrong about storage,
  both times from extrapolating a small fixture.** Anything storage- or depth-related has to be
  measured at target scale or not claimed.
- **delta compression** — 10 assertions (240 total + 15 CLI + 9 kill). Built as a **repack step**
  like git's, so the write path is untouched and commits stay at 25 ms; `grove.repack()` / `grove gc`
  rewrites older chunk versions as deltas against the next newer one, and `grove.unpack()` reverses
  it. Content addressing survives because a node's hash stays the hash of its *logical* content —
  the delta is a storage form only, and the tests pin that: after repack every node resolves to
  byte-identical entries, no tree root moves, `diff` and `blame` return the same rows, a fresh full
  rebuild still matches.
  **The depth default was the whole engineering decision, and my first guess was 50× wrong.** At
  depth 50 storage drops 66% and diff goes from 167 ms to **7,071 ms — 42× slower**. The curve is
  brutally non-linear; depth 1 gives 34% of the storage for 11% of the read cost and everything past
  2 falls off a cliff. Default is 1. The cause is that applying a delta rebuilds and re-sorts a
  64-entry jsonb array, so each hop costs O(chunk) — git affords chains of 50 because its deltas are
  byte-level copies.
  Two measurement traps in one tick: `pg_total_relation_size` cannot shrink inside a transaction
  because `UPDATE` leaves dead tuples, so the first storage assertion failed on the instrument rather
  than the optimisation (fixed by summing `pg_column_size`); and a timing query that computed
  `clock_timestamp()` and the measured query in the same `SELECT` reported 0 ms for everything.
- **byte-splice deltas** — no new assertions (240 + 15 + 9 all still green); the delta *format*
  changed underneath them, which is the point: the tests never had to know. Deltas were a relational
  rebuild — expand entries to rows, anti-join, re-aggregate with a sort — costing O(chunk) **per hop**.
  They are now `(prefix_len, suffix_len, middle)` against the serialised node, applied with `substr`
  and `||`, which are memcpy inside Postgres. A chain splices text through every hop and parses jsonb
  **once at the end** instead of rebuilding at each step.
  **At depth 50 that is 7,071 ms → 1,248 ms, 5.7× faster**, which moved the default from 1 to **4**:
  54% of the node store for a read cost inside run-to-run noise. Depth 16 buys 64% at roughly 2×.
  Worth recording why: this was raised as the case for rewriting in C, and **it did not need C**. The
  bottleneck was never the language, it was using jsonb as the node format on the hot path. What is
  still missing is a packed binary node format — every resolution parses jsonb once at the end and
  every entry still carries its column names, and that last parse is what caps useful depth near 16.
- **AC-PORT-02** — 12 checks in `test/rds_test.sh`, wired into `make test` (276 total across four
  suites). A plain `LOGIN` role with no superuser rights runs the whole verb set — **stricter than
  RDS**, where the master user is `rds_superuser`, so passing here covers RDS, Neon and Supabase by
  construction.
  The portability claim had been asserted in the README all night and never tested. Testing it found
  a real dependency immediately: `session_replication_role` is superuser-only, so **`revert` and
  `checkout` failed outright** while everything else already worked. `grove.replay_begin()` now tries
  the GUC and falls back on `insufficient_privilege` to disabling each non-grove trigger by name,
  restoring its exact prior state afterwards — asserted, since `ENABLE TRIGGER USER` would have
  flattened an `ENABLE ALWAYS` trigger to `ENABLE`.
  The fallback is arguably the better path: `DISABLE TRIGGER` skips internal triggers, so
  **referential integrity stays enforced during replay**, closing the FK gap replica mode left open
  and listed under Follow-ups. It costs an ACCESS EXCLUSIVE lock per tracked table.
- **conflict resolution** — 19 new assertions (259 pgTAP + 19 CLI + 9 kill + 12 RDS = 299). Before
  this, `grove.conflicts` was **written and never read** — a conflicted merge reported a count,
  applied nothing, and offered no way forward. Now: `grove.merges` tracks an in-progress merge,
  conflicts carry a resolution, and `resolve_conflict` / `resolve_all` / `merge_finish` /
  `merge_abort` close the loop. CLI: `grove conflicts`, `grove resolve`, `grove merge --continue`,
  `grove merge --abort`.
  **`-X ours` / `-X theirs`** resolve every conflict to one side while still taking the other
  branch's *non-conflicting* changes — the git semantic, and asserted as such, since the naive
  reading ("take our whole tree") is a different feature. That different feature is `-s ours`,
  implemented separately as `-s ours` / `opt='ours-tree'`.
  **Criss-cross histories now merge instead of refusing.** With two merge bases, `merge_base`
  synthesises a **virtual base**: it materialises one base's rows into a temp table shaped `LIKE` the
  real one, applies the merge of the two bases to it, writes a tree, and registers it under a
  synthetic sha with no commit row. The test builds a genuine criss-cross — two branches that merged
  each other's tips independently — asserts there really are two merge bases, and that the base used
  is synthetic. Conflicts *within* the virtual base take the first base's side, which is a heuristic
  and is documented as one. More than two bases still refuses loudly.
  Still absent, deliberately: octopus merges, `subtree`, `rerere`, and rename detection in merge.
- **rename detection in merge** — 9 assertions (268 pgTAP + 19 CLI + 9 kill + 12 RDS = 308). The
  row analogue of git's file-rename detection: **a primary-key change is journalled as a delete plus
  an insert**, so if the other branch edited that row you previously got a spurious delete-versus-
  modify conflict *and* silently lost the edit. `grove.rename_pairs` pairs deleted keys with inserted
  ones by `grove.row_similarity` over non-key columns — mutual-best-match, one-to-one, default
  threshold 0.5, the same shape as git's `-M`. `merge_plan` is now a wrapper over `merge_plan_raw`
  that rewrites those conflicts into a three-way merge **at the new key**.
  Tested in both directions, which matters more than the happy path: a key change with an otherwise
  untouched row scores similarity 1.0 and merges cleanly, carrying the other branch's edit onto the
  renamed row; a delete-plus-insert of *dissimilar* content is **not** mistaken for a rename and
  still surfaces as a real conflict; and raising the threshold above 1.0 finds nothing, proving the
  threshold is actually honoured rather than decorative.
  `grove.rename_pairs` is public, so wiring `-M` into `diff` later is a small change. Still absent by
  choice: octopus merges, `subtree`, `rerere`, and **table**-level rename detection (a table renamed
  by DDL is currently refused by the schema-fingerprint guard rather than followed).
- **fsck, revisions, reset/reflog, working-tree diff** — 30 new assertions (291 pgTAP + 26 CLI +
  9 kill + 12 RDS = 338).
  **`grove.fsck`** recomputes every node's hash from its children, follows every delta chain, and
  checks refs, commit parents, tree roots and child links. It reports zero on a healthy repo *and*
  zero after `repack(50)`, which is the useful part — it verifies delta chains end to end. It is
  also tested **negatively**: a tampered node is caught, and a delta pointing at a missing base is
  caught. Without those two, "fsck returns 0" would be indistinguishable from "fsck checks nothing".
  **`grove.rev`** gives `HEAD`, `HEAD~N`, `HEAD^`, `HEAD^2`, branch names and abbreviated shas, and
  the CLI now routes `show`, `diff`, `revert` and `cherry-pick` through it — so the tool takes
  revisions instead of 64-character hashes.
  **`log`** gained `-n`, `--author` and `--since`. **`reflog`** records every ref movement, which
  came almost free because `advance_ref` was already the single choke point for ref updates.
  **`diff_working`** compares the live tables to HEAD, closing AC-DIFF-11 which had been written and
  never built.
  **`reset --hard` had a real bug the CLI test caught**: it diffed the old ref against the target, so
  `reset --hard HEAD` did nothing to a dirty tree. Git compares the *working tree* to the target. Now
  it does too — `apply_diff` was split into `apply_tree_diff` taking roots directly, and reset
  computes the live root with `write_tree`. Pinned by an assertion in the SQL suite as well as the
  CLI one.
- **remotes** — 13 checks in `test/remote_test.sh` across **two real databases** (351 total across
  five suites). History moves as a **bundle**: a single self-contained jsonb value carrying commits,
  trees, schemas and fully-materialised nodes. No `dblink`, no `postgres_fdw`, no network coupling —
  which is what keeps the RDS story intact and makes the whole thing testable locally.
  `grove.bundle(refs, have)` does real **negotiation**: commits are walked back only to what the
  receiver already has, and nodes reachable from the receiver's existing trees are excluded. Measured
  in the test: a full pack is 15 nodes, the incremental after one commit is **3**.
  Two properties are worth more than the rest. **The clone's tree hashes identically to origin's** —
  content addressing means the transfer is verifiably exact rather than merely plausible. And
  `unbundle` **recomputes every node's hash from its content and refuses on mismatch**, so a tampered
  or corrupted pack cannot enter the object store; the test tampers with a node and asserts the
  rejection.
  `fetch` updates `remotes/<name>/*` only and never touches local branches; `receive` updates local
  branches with a **fast-forward check** that `--force` overrides. Both are asserted.
  Three harness bugs cost most of the time, all mine: a shell-built `bytea[]` literal that mangled
  the escaping, `array_agg` returning NULL rather than an empty array for a fresh clone, and the one
  worth remembering — **psql does not interpolate `:'var'` in `-c` strings**, only in `-f` or stdin
  input, so every bundle transfer silently did nothing while reporting success.
  Not built: `clone` does not create tables from the recorded schema, so the receiving database needs
  its own DDL first. That is arguably right for a database tool, where migrations own DDL, but it
  means `clone` is `receive` plus your own `CREATE TABLE` rather than one command.
- **tags, restore, stash, bisect, prune** — 20 assertions (371 total across five suites).
  **`tag`** is a separate table rather than a ref, with annotated message and tagger, and `grove.rev`
  resolves tag names — so `grove show v1.0` works. Re-tagging is refused without `-f`.
  **`restore`** brings a table or a **single row** back from any revision without moving the branch,
  which is the operation people actually want from a database ("put products back to Tuesday").
  Asserted that restoring row 5 leaves row 6's independent change alone.
  **`stash`** is a commit on an anonymous `stash/N` ref: commit, point the branch back, hard-reset.
  Pop applies the stash's diff *against its own parent*, so it is a patch rather than a snapshot
  overwrite. Reuses `commit`, `reset` and `apply_tree_diff` entirely — no new machinery.
  **`bisect`** narrows over the ancestry between good and bad, checking out the midpoint each step.
  The test builds ten commits where a value goes wrong at the sixth and asserts the search
  **converges on c6** — a bisect that always answered "the tip" would fail it.
  **`prune`** truncates history before a cutoff, re-roots the boundary commit, and then `gc_nodes`
  deletes every node unreachable from a surviving tree — following **delta base chains** so a kept
  node's base is never collected out from under it. The decisive assertion is that **`fsck` is clean
  after pruning** and the surviving tip still hashes to the live table: proof that nothing reachable
  was collected.
  The parameter-shadowing trap bit **twice more** — `slot` against `stash_list()`'s column, then
  `sha` against `refs.sha` in an `INSERT … VALUES`. That is the third and fourth time tonight from
  the same cause, in a codebase where I had already written the rule down. plpgsql resolves
  ambiguity in favour of an error, which is the merciful outcome; the rule needs to be *prefix every
  local*, not *remember to check*.
- **clone as one command** — 9 more checks in the remote suite (380 total across five suites).
  The gap was that `grove.schemas` recorded column names and types but **not the primary key**, so a
  receiving database could not build the table. `pk_cols` is now recorded, travels in the bundle, and
  `grove.clone_from` creates each missing table from the recorded shape, tracks it, sets the branch and
  materialises the data.
  Tested against a database with **no DDL of its own**: it asserts `to_regclass('t') IS NULL` first,
  then that one call created the table, tracked it, moved HEAD, brought all 300 rows, and that the
  materialised table **hashes to exactly what the cloned commit records**. Cloning over an existing
  history is refused.
  Honest limitation: the recorded shape is what canonical hashing needs — column names, types, primary
  key. Clone does **not** reproduce foreign keys, defaults, checks or secondary indexes, so it builds
  a table that holds the data and hashes identically, not a faithful DDL copy. For a tool where
  migrations own DDL that is the right boundary, but it should be read as "clone the history", not
  "clone the schema".
  Also fixed a real annoyance found by the test: `grove.track` was emitting `DROP TRIGGER IF EXISTS`
  notices on every call, so any script using it filled the console with noise. Silenced at source.
- **tooling** — the progress log above lost 11 entries to silent failure. They were appended with a
  Python `str.replace()` anchored on text that did not exist, and `replace()` returns the original
  string on no match, so every one reported success and wrote nothing. The `## Blocked` section
  referenced from "Next" was never created either. Reconstructed from the session transcript.
  **Use a tool that fails loudly, or assert the match count — never a silent string replace.**
- **notes, rerere and table rename detection** — the three items from the missing-functionality
  inventory that genuinely apply to a row-oriented system. 16 pgTAP assertions, 10 CLI checks.
  `grove.notes` attaches text to a commit sha; `grove notes add|show|rm|list`.
  `rerere` records `(tbl, base, ours, theirs) → resolution` on `merge --continue` and replays it
  automatically the next time the identical conflict appears, so a repeated branch merge stops asking.
  The test proves this is not vacuous: it asserts the `used` counter incremented before checking the
  conflict count dropped to zero — otherwise "no conflicts" could just mean the second merge differed.
  `grove rerere status|forget`.
  **Table rename detection uses tree similarity, not shape.** Comparing column names and types
  false-positives constantly — `(id int, v text)` is every other table. It matches by content
  instead: Dice coefficient over `(key, row hash)` leaf pairs, threshold 0.5, best match per dropped
  table. Identical roots score 1.0 without descending. A rename plus an edit of 2 of 10 rows scores
  exactly 0.8 and is reported as `similar`; a drop and an unrelated add sharing no rows is not
  reported at all. `grove renames <a> <b>`.
  Two things worth recording. The first draft joined on `root_hash = root_hash`, which made the
  `'similar'` arm of its own CASE unreachable — it could only ever detect a rename with no edits,
  while the column claimed otherwise. Dead code that lies in a report is worse than a missing feature.
  And the outcome is still **detection, not following**: `assert_same_schema` refuses the replay, but
  now names both tables and the match percentage instead of blaming a shape change. Following a rename
  through a merge means mapping the old name to the new one across the diff, conflict and journal
  paths; that is a project, not an afternoon, and is deliberately not attempted.
- **octopus merges** — `grove merge a b c` and `grove.merge_octopus(text[])`. 19 pgTAP assertions,
  4 CLI checks, 5 remote checks. This closes the last verb in the inventory that applies here.
  The schema change was the point of it: `parent2_sha` is **gone**, replaced by
  `grove.commit_parent (commit_sha, ord, parent_sha)` with `ord >= 2`, plus a `grove.parent_edge` view
  that unions the first parent with the rest and a `grove.parents_of(sha)` accessor. Eight call sites
  moved onto the view — `ancestors`, `rev` (`^N` now reaches any parent, not just the second),
  `fsck`, `commits_to_send`, `bundle`, `unbundle`, `prune`, `merge_finish` — and the two tests that
  read the old column. The bundle format carries a `parents` array; the wire format changed and there
  is no reader for the old one, per the no-back-compat rule.
  **The reason this stayed cheap is git's own choice: octopus refuses to resolve conflicts at all.**
  Once that is accepted there is no sequential three-way state machine to build. `grove.octopus_plan`
  diffs every head against one common base, groups by `(table, key)`, and counts distinct resulting
  images: one image means every head that touched the row agrees, so apply it; two or more means
  refuse and name the row. Two heads making the *identical* edit is therefore not a conflict, which
  matches git and is asserted.
  One deliberate deviation, recorded because it is a real difference: git recomputes the merge base
  per head against the accumulating set, and this takes a single base folded over all heads. That
  base is the same for the case octopus exists to serve — N branches off one trunk — and is *older*
  for tangled topologies, which means more rows look changed and the merge is more likely to be
  refused. The failure direction is "refuses and tells you to merge one at a time", never a silent
  wrong result.
  Two test-side lessons. The refusal first named the row by its canonical key hash
  (`t.69643d23313a357c`), which is unusable in an error message — it now renders the primary key
  (`t(id=5)`). And the new remote checks failed at first for a reason that had nothing to do with
  octopus: the earlier `receive --force` test leaves origin's live table out of step with its ref, so
  `checkout` refused. The setup block was swallowing stderr with `2>&1 >/dev/null`, so a hard error
  read as a wrong answer. Those blocks now run with `ON_ERROR_STOP=1` and only stdout suppressed.

- **delta compression rewritten to git's copy/insert op list** — 16 pgTAP assertions. A single
  `(prefix, suffix, middle)` splice can only describe one contiguous changed region, so two rows
  changed at opposite ends of a chunk forced the middle to span everything between them. Measured on
  the **same 424 node-version pairs**: one splice beat the full node on 370 of them for 646 kB total;
  the op list beats it on **424 of 424 for 150 kB**, and the mean leaf delta drops from 3,398 B to
  541 B against a 9,057 B node. End to end, 2,506 kB → 473 kB. Full numbers in `PERF.md`.
  The first attempt emitted the array separator as a copy from a **fixed** base offset, so no two
  copies were ever contiguous, nothing coalesced, and a 123-entry leaf produced 247 ops and a delta
  *larger* than the node — while packing exactly the same node count, so it looked like it worked.
  Every delta is now checked against its target at construction and falls back to a whole-node insert
  if it would not reconstruct, so correctness never rests on the offset arithmetic.

- **run grove against a real application database, not a fixture** — `bench/realworld_intoge.sh`,
  19 checks against a restored 63-table e-commerce schema: 21 custom enum types, `jsonb`, `numeric`,
  `date`, `timestamptz`, real foreign keys, Georgian and Russian text. It tracks every table with a
  primary key, commits a baseline, then runs workflows the application would actually perform — a
  10% price rise on a branch, a translation pass on main, a merge, a genuine two-sided price conflict
  with resolution, and a merge that would dangle a real `ON DELETE RESTRICT` foreign key.
  **It found three real bugs that 380 synthetic assertions had not.** Each has its own regression
  test, and each was confirmed to fail without its fix:
  1. **The incremental tree and a full rebuild disagreed on the root hash when a table shrank to a
     single chunk.** `build_up` stops at the first level holding one node, so a one-chunk table's root
     *is* its leaf; the incremental path built level 1 unconditionally and returned a node wrapping
     that leaf. Same rows, same per-key hashes, different root — which breaks the one invariant the
     whole design rests on, since two databases holding identical content would disagree and `fsck`
     would call both of them healthy. Found because a cascading delete shrank a locale table.
     `test/incremental_04_collapse.sql`, 8 assertions.
  2. **`apply_row` could not write a table with a `GENERATED ALWAYS AS` column**, which is every
     checkout, merge, revert, rebase and reset on such a table. `all_columns` is now
     `writable_columns` and excludes generated columns; identity keys are handled too — they are
     omitted from the `SET` list, since the key is already matched in the `WHERE`, and inserted with
     `OVERRIDING SYSTEM VALUE`. `test/replay_06_unwritable_columns.sql`, 10 assertions.
  3. **`blame` ignored branch topology.** It scanned `grove.changes` globally, so a row edited or
     deleted on a branch you are not on was attributed on yours — a row deleted on an unmerged branch
     blamed to all-null values. Now restricted to commits reachable from HEAD plus uncommitted rows.
     `test/blame_02_branch_scope.sql`, 7 assertions.
  Two things about the harness itself. Its first run reported four passes that were **vacuous** —
  `grove.track(r.relname)` failed because `relname` is `name` and there is no implicit cast to `text`,
  the error was swallowed by a `>/dev/null`, and every later assertion compared zero against zero. It
  now refuses to run if tracking produced no tables. And two "failures" were the harness being wrong,
  not grove: Postgres words a RESTRICT violation as `violates RESTRICT setting of foreign key
  constraint`, not `violates foreign key`, and `blame.actor` is who changed the row, not who authored
  the commit.

- **a commit rebuilt every table it did not touch** — found by versioning IMDb's `title_basics`
  (12.7M rows, 1.9 GB) alongside a small table that changes nightly, which is the shape of every real
  application: many tables, one of them big, most untouched per commit.
  `write_tree_incremental` guards with `array_length(changed, 1) IS NULL` — *nothing in this table
  changed* — and fell through to a full `grove.write_tree(target)`. **The cheapest possible case took
  the most expensive path.** An unchanged table now returns the root its parent commit recorded.
  Measured at 100k rows: a commit touching only the small table costs **44 ms** with the fix against
  **1,525 ms** for one rebuild of the untouched table alone — 35× the whole commit, and the ratio
  grows with the table. On the IMDb fixture each nightly commit was rebuilding 12.7M rows at ~6
  minutes a time; 30 nights would have taken about three hours instead of about one minute.
  It stayed hidden because the synthetic bench tracks exactly one table and always changes it, and
  because the 63-table application schema is small enough that rebuilding all of it costs ~1 s. It
  only bites when more than one table is tracked and one of them is large, which is the normal case.
  **The regression test needed a timing assertion, and that is the lesson.** The nine correctness
  assertions written first all pass *without* the fix, because a needless rebuild produces exactly
  the same root hash — the defect is invisible to any check on values. The tenth compares, inside one
  run, the cost of a commit touching only the small table against one rebuild of the big one, so it
  is machine independent; it is the only one that goes red when the guard is removed.
  `test/incremental_05_untouched_tables.sql`, 10 assertions.

- **commit cost depended on the shape of a change, and the journal lost rows on some schemas** —
  three more findings from real data, 16 pgTAP assertions.
  **Scattered changes were quadratic.** Locating which chunk each changed key belongs to tested every
  chunk against the whole changed array — `O(chunks × keys)`, 132 million comparisons at 1.7M rows,
  40 s of a 57 s commit. Now one indexed range probe per key. The scratch tables gained a
  `COLLATE "C"` index, which the hex keys wanted regardless: every other ordering in the tree is byte
  order, so the default collation was both a latent inconsistency and an unusable index.
  Full table in `PERF.md`; the short version is 5,000 scattered rows went 53.2 s → 13.4 s, 5,000
  adjacent rows 1.4 s → 125 ms, and the worst case is now bounded by a full rebuild.
  **A threshold tuned by guesswork made things worse.** The first bail-out fired at one sixth
  coverage and cost 500 scattered rows 2.5× (6.8 s → 17.2 s) by forcing a rebuild that had not become
  worthwhile. Measuring the crossover moved it to three quarters. Worth remembering that the guard
  was *added* as a fix and was itself a regression until measured.
  **The journal silently recorded a scalar instead of the row** when a tracked table had a column
  named `n` or `o`: the statement trigger read `to_jsonb(n)` over `FROM newrows n`, and an
  unqualified name resolves to the column, not the alias. Nothing failed at write time — the commit
  blew up later with `cannot call populate_composite on a scalar`, pointing at a query that looked
  fine. A column named `cols` broke it a third way, colliding with the trigger's own plpgsql local.
  Aliases are now `grove_nr`/`grove_or` and locals are prefixed.
  **This is the fifth and sixth time an unprefixed identifier has cost real debugging time**, after
  the four parameter/local shadowing incidents already recorded. The rule is not "remember to check" —
  it is *prefix every local and every alias mechanically*, including in trigger bodies, where the
  colliding name comes from a user's schema rather than from this codebase.

- **diff was 16x slower than it needed to be** — `bench/realworld_imdb.sh`, versioning IMDb's nightly
  ratings feed (12.7M + 1.7M rows, 2.6 GB). 10 pgTAP assertions.
  Diffing 30 nights apart returned 83,798 changed rows in **608 s**, against a design goal of
  O(difference). The descent was fine; the resolution was not. After 30 nights nearly every chunk
  differs, so the descent yields ~3.4M candidate keys, and `diff_tree` discarded everything the
  descent knew about them and did **two root-to-leaf walks per candidate** to decide. The descent
  already carries each candidate's row hash on both sides, so a key present on both is decided by
  comparing them. **608 s → 37 s**, same 83,798 rows, measured as an A/B on the same database with
  only the function replaced.
  **The obvious version of this is wrong, and it is worth writing down why.** A key seen on only one
  side proves nothing: the descent skips chunk pairs that are *identical*, so an unchanged row can be
  emitted from side `a` while its counterpart on side `b` sits in a chunk that was never visited.
  Treating one sided keys as inserts or deletes reports rows that never changed — a contiguous range
  delete triggers it. Those keys still need a lookup; only the two sided majority avoid one.
  This was proposed on a reading of the pairing join that said the lookups were vestigial. They are
  not, and `BUILD_PLAN` already said so. The first version passed all four existing diff tests
  including the journal oracle, and was caught only by `test/diff_05_descent_oracle.sql`, which
  computes the diff by full scanning both trees and joining on the key — **no shared code with the
  thing under test**. A differential oracle earns its place precisely when the plausible-looking
  change is wrong.
- **prune destroyed pending work** — `prune` marked journal rows of pruned commits with
  `commit_sha = NULL`, then deleted every `NULL` row. But `NULL` is also how a row says *not yet
  committed*: a prune between a write and its commit silently threw the uncommitted work away, and
  the next commit recorded a tree that did not match the table. Fixed by deleting by predicate
  instead of via a tombstone that collides with a real state. 5 assertions in
  `test/replay_07_prune_pending.sql`, suite 626 green. The real surprise was the fuzzer: it did not
  catch this, because its tables held 40 rows, and at 40 rows the root is level 1, and
  `write_tree_incremental` short circuits a level 1 root to a full rebuild. Every fuzz run since
  the incremental path was written had been exercising the *other* path. Fuzz tables are now 6000
  rows (root level 2), and with the bug reintroduced the fuzzer fails on operation 6.
- **six bugs found by using it like a user** — driving grove through ordinary flows (track an
  existing table, branch, merge, resolve, revert, clone) turned up what the suite never asked.
  1. `blame` read only the journal, so every row that existed **before** `track()` was permanently
     unblameable and returned zero rows with no error - the normal onboarding path. It now falls
     back to the tree and attributes those columns to the commit that first recorded the row.
  2. `commit` minted a commit when nothing had changed; an hourly job would have added 8,760 empty
     commits a year. It refuses now, with `allow_empty := true` for the deliberate case. The first
     version of that guard was too strict and `ddl_01` caught it: `ALTER COLUMN a TYPE varchar(50)`
     leaves every canonical value identical, so the tree is unchanged while the *shape* is not.
  3. `needs_attention()` returned nothing while a merge sat unresolved, so a monitor following
     `RUNBOOK.md` would report green with the database stuck mid-merge. Merge, conflicts, bisect and
     rebase are all surfaced now.
  4. `revert` applied its inverse but never committed, while its sibling `cherry_pick` did. The
     dangling change silently folded into whatever the user committed next - it happened to me
     mid-session, landing a revert inside an unrelated commit about a different table. `revert` now
     commits, returns the sha, and names what it reverted.
  5. Every commit had a blank author: `actor()` was `current_setting('grove.actor')`, documented
     nowhere. It falls back to `current_user`, which also makes `log(who := ...)` useful for the
     first time.
  6. `clone_from` recreated tables with columns in **alphabetical** order. A positional
     `INSERT INTO inv VALUES ('D', 7, 'shelf')` written against the source put `sku='shelf'` and
     `loc='D'` in the clone, no error. Column order is part of a table's shape, so it is recorded in
     table order now - an on-disk format change, so `format_version` is 4.
  20 new assertions across `ux_01`, `ops_02`, `clone_01` and `remote_test`; suite 646 green. The
  lesson worth keeping: every one of these sat behind a green 626-check suite, because the suite
  tested what I thought to test and never once used the thing the way its README tells you to.
- **gc could break the next commit on a branch** — found while making CI faster, which is not where
  I expected to find a data bug. `repack` packs a node by setting `entries`, `hashes` **and** `keys`
  to NULL and storing a delta, but `splice_touched_chunks` reconstructed only `entries` and read
  `hashes`/`keys` straight off the row. Splice a packed leaf chunk and every field is NULL, so
  `grove.hash(NULL)` is NULL and the commit dies on the `nodes.hash` NOT NULL constraint. Repack keeps
  the **newest** version of each chunk whole (`ORDER BY n.seq DESC`), so the victim is any branch
  that is not the most recent writer of a chunk: branch, commit a few times on main, run the nightly
  `repack()`, commit on the branch - crash. Reproduced at the default `chunk_target` of 64.
  `nodes_at_level` had the same bug, reading `n.keys[1]` raw. Both use `grove.node_raw()` now, which
  already reconstructed all three. Guarded by `gc_02_commit_after_repack.sql`, proven red first.
- **the fuzzer needed deeper trees, not bigger ones** — raising fuzz tables to 6000 rows cost 6.5x
  per operation and pushed the CI campaign towards an hour. A `chunk_target` of 8 with 400 rows gives
  a **level 3** root instead of level 2, at 4s per 100 operations instead of 13s. Better coverage,
  a third of the cost, and it is what found the repack bug above.
- **the benchmark had stopped measuring one of its own numbers** — the empty-commit guard refused a
  commit in `bench/quick.sh`, which turned out to be right: the "100 adjacent rows" step updates
  `tconst BETWEEN 'tt00050000' AND 'tt00050099'`, and when the key widened to 12 digits that range
  stopped matching any row. It had been timing a no-op commit. Now 14ms of real work.
- **observability** — every write verb emits one wide event rather than scattered lines:
  `grove.events` holds verb, ok, actor, branch, duration_ms, txid and a jsonb detail carrying the
  sha, row counts and conflict counts. `log_server` also RAISEs it as a single JSON line for Loki,
  with `log_error_verbosity` scoped to `grove.emit` so Postgres does not staple CONTEXT to every
  event. `grove.metrics()` is the numeric side for scraping, including commit latency p50/p95 taken
  from the events themselves. `repack` rotates the table on `log_retain_days`. Events are
  transactional, so a rolled back operation leaves no trace - which also means failures need
  `log_server`, and the runbook says so. 12 assertions, perf gate unchanged, suite 661 green.
  One trap on the way: scoping `SET log_error_verbosity = 'terse'` to `grove.emit` to stop Postgres
  stapling CONTEXT onto every event is a **superuser only** GUC, so it made `commit` fail for
  exactly the unprivileged role a real application runs as. `privileges_test.sh` caught it. Terse
  logging is a server setting for the operator, not something grove can arrange for itself.
- **`remote` was half a feature, and the half that was missing was not written down** — `remote_add`
  stores a name and a URL, and **nothing anywhere reads the URL**. Proven rather than inferred:
  `remote_add('origin', 'this-is-not-a-url-at-all ://// nonsense')` is accepted, and
  `fetch('never-registered', bundle)` succeeded and created `remotes/never-registered/main` for a
  remote that had never been added. The ref side is genuinely right - fetch touches only
  `remotes/<name>/*`, receive enforces fast forward, both verify every node hashes to its content -
  but there is no transport, and there cannot be one while grove stays extension free, because that
  needs `dblink` or `postgres_fdw`. The README's `remote add origin <url>` implied otherwise.
  `fetch` now refuses an unknown remote and says how to add it, `LIMITATIONS.md` states plainly that
  grove never dials anything and shows the bundle-by-hand recipe, and the README calls the URL a
  label. The existing remote suite had been fetching without ever adding a remote, which is how the
  gap survived 28 green checks; it registers one now. REMOTE 29.
- **hunting with the instrument turned on** — running ordinary workflows and reading `grove.events`
  rather than the tables found what the tables could not show.
  1. **A rebase left no trace at all.** It rewrote history - old tip abandoned, new commit created -
     and emitted nothing, not even a `commit` event, because `rebase` and `cherry_pick` build commit
     rows directly instead of calling `grove.commit`. Measured across a normal workflow: **5 commits
     created, 4 commit events**. `cherry_pick`, `merge_octopus`, `reset`, `restore`, `branch`, `tag`,
     `track`, `untrack`, `delete_branch` and `stash` were all invisible too. `reset` can drop commits
     and `restore` writes rows; both were silent. All instrumented now, and
     `obs_02_every_commit_audited.sql` locks the invariant that **every commit in the database has a
     commit-creating event**, whatever verb built it - so the next verb that forgets fails the suite.
  2. **`blame` named the wrong person after a routine prune.** Before pruning, `title` was bob's.
     After a 45 day retention prune removed bob's commit, blame reported **carol** - who had only
     ever touched `body` - because the tree fallback attributes unexplained columns to the oldest
     surviving commit. The value was right and the author was wrong, which is worse than no answer.
     `blame` now returns `exact`: true when a journal entry proves that commit changed that column,
     false when the value was merely already present there. `RUNBOOK.md` says never to attribute a
     false row to a person, and `LIMITATIONS.md` records that prune buys storage with attribution.
  3. **The rebase event claimed `rewritten: true` unconditionally**, including for a fast forward
     that rewrote nothing. It is computed now - history was rewritten only if the old tip is no
     longer reachable from the new one, which is git's own definition. The no-op and conflict exits
     of `rebase` emit too, so a rebase that stopped half way is on the record with `ok = false` and
     `stopped_at`, alongside `needs_attention` showing it.
  Checked and found correct on the way: rebase content, octopus (4 parents, disjoint keys all
  present), FK cascade across a merge (0 orphans after a branch deleted parents that main had added
  children to), and a 30 night ETL over 50k rows where commit latency stayed **flat at ~490ms**
  (p50 486, p95 504) with no drift. One unexplained `PGTAP RED (1 of 520)` that did not reproduce in
  three further runs and whose assertion name I did not capture - recorded here rather than assumed
  away.
- **the unexplained RED was the harness lying** — chasing it down found two defects in `test/run.sh`
  itself. It sets `FAILED=1` from three different conditions - a failed assertion, a file that did
  not finish its plan, and a SQL error - but the summary printed only the failed-assertion count, so
  a file that died before running its assertions reported **`PGTAP RED (0 of 463 failed)`**: red with
  nothing failed and the reason already scrolled off. That is exactly how I lost the earlier one.
  The summary now counts all three and names every file that broke. Second defect: `run.sh` hardcoded
  the database `grove_pgtap` and dropped it on exit, so two runs at once silently destroyed each
  other's database mid-suite and produced garbage - which is what I had actually done to myself. It
  uses `grove_pgtap_$$` now, and two concurrent runs both report GREEN.
- **the rest of the audit gaps closed** — `revert` was recorded only as the commit it produced, and
  `merge_abort`, `rebase_abort`, `resolve_conflict`, `tag_delete`, `note_add` and `bisect_start`
  emitted nothing at all. `merge_abort` discarding resolved conflict work and `resolve_conflict`
  choosing a side are the two an audit asks about most, and both were silent. All emit now, aborts
  with `ok = false` so throwing work away lands in `grove_events_failed`. 6 assertions in
  `obs_03_destructive_verbs.sql`.
- **the perf worry was the machine, not the code** — gate medians drifted 847 → 897 → 943ms across
  the session and the ranges stopped overlapping, which reads exactly like a regression. A/B on the
  same machine state settled it: pre-instrumentation 939/307/512ms against instrumented
  **907/288/511ms**, so the instrumented build is equal or faster and the drift was the machine.
  Worth the two minutes; guessing either way would have been wrong.
- **the fuzzer found a tree that disagreed with its own table, and CI caught it before a user did** —
  PG 18 went red on master with `fuzz: op 240 left 1 tree(s) disagreeing with a rebuild`, seed
  0.772185. 16 and 17 passed, which is the matrix earning its place. The recorded tree held **443
  leaves, 378 distinct keys, 65 of them stored twice**: no data lost or altered, but the root hash
  could never match a rebuild.
  `locate_touched_chunks` sets each leaf chunk's upper bound with `lead(k) OVER (ORDER BY k)`
  computed across the items of the **hit** level 1 nodes only. When the hit nodes are not adjacent,
  the last chunk of one gets an upper bound taken from the first chunk of the next hit node, which
  lies beyond the untouched nodes in between. `rebuild_touched_ranges` then rebuilds that whole span
  from the live table while the untouched level 1 subtrees are still retained, so every key in the
  gap is recorded twice.
  The first fix partitioned the rebuild groups by their level 1 node, which was wrong in a way the
  suite caught immediately: content-defined chunking has to be free to run across a node boundary,
  and forcing a break there made a 3000 row contiguous delete produce different chunks than a full
  rebuild (`incremental_02`). The real predicate is key coverage, not node identity - a run breaks
  where one chunk's upper bound is not the next chunk's lower bound. Bounding `nk` by its own node's
  `nk` and grouping on that continuity fixes both.
  No synthetic reproduction was found: 20 constructed delete shapes all missed, because the bug needs
  the *last* leaf chunk of one node and the *first* of a later one to both be hit. Rather than ship a
  test that passes either way, seed 0.772185 is pinned in `fuzz_test.sh` as a regression seed that
  runs on every invocation. It is red without the fix and green with it, which is the property a
  regression test has to have.
  Two other CI runs had failed the same way on **PG 16**, seeds 0.775743 and 0.319870, at ops 116
  and 195. So the first read of this - "18 fails, 16 and 17 pass, therefore version specific" - was
  wrong. It was never about the version. Three of the last five runs on master failed and one passed,
  purely on which random seeds each drew. All three seeds pass with the fix and all three are pinned.
- **dropping a tracked table stopped all versioning, silently** — a migration that drops a tracked
  table leaves its oid in `grove.tracked`, and from then on **every** `grove.commit()` fails with
  `grove: table 3592960 has no primary key`. The oid because the name is gone, and the wrong diagnosis
  because the real problem is that the table does not exist. `fsck` reported **0 problems** and
  `needs_attention()` was empty, so nothing anywhere said versioning had stopped. For a project whose
  schema is owned by drizzle migrations, dropping a table is routine.
  `grove.tracked` now records `name_at_track` so the table can still be named after it is gone,
  `grove.missing_tracked()` finds them, `grove.untrack_missing()` clears them, `fsck` reports
  "tracked table no longer exists", `needs_attention` surfaces it, and the commit error says which
  table and what to run. The dropped table's recorded history is kept, so its old rows are still
  readable through `diff` and `restore`. 8 assertions in `ddl_03_dropped_tracked_table.sql`.
  Two self-inflicted errors on the way, both caught by the suite rather than by me. Naming the new
  column `tbl_name` collided with the **parameter** of that name in `grove.blame` and
  `grove.row_matches`, making `WHERE tbl::text = tbl_name` ambiguous and breaking four unrelated test
  files. And `missing_tracked()` returning a column called `tbl_name` collided with the same column
  inside its own body. Adding a column to a shared metadata table is not a local change.
- **the chunk_target=4 divergence does not reach the default** — 3000 operations at `chunk_target=64`
  over 8000 row tables came back clean, so the level 1 regrouping defect found by `hunt.sh` is
  confined to very small chunk targets. Recorded rather than fixed: `build_one_level(1)` re-chunks
  only the leaves under hit level 1 nodes and trusts a plus-or-minus-one neighbour expansion for
  context, and nothing proves one neighbour is always enough. At a target of 4 an L1 node holds about
  four leaves, so a change reaches past its neighbour.
- **a reproduction that was my own contamination** — the "deterministic minimal repro" of that
  divergence, 220 rows and a delete of ids 34 to 38, turned out to be an artifact: the search loop
  dropped and recreated the table while it was still tracked. On a clean database the same case
  passes. It was worth checking rather than reporting, and the contamination is what exposed the
  dropped-table bug above.
- **a bundle did not say what it was built with** — a new round-trip hunt (`roundtrip_test.sh`: fuzz a
  database, bundle it, clone into a fresh one, compare) failed on its first three seeds. The clone
  received **bit identical roots** and was **fsck clean**, and every one of the 600 rows matched its
  recorded image exactly, yet `write_tree` in the clone disagreed with the history it had just
  received. The bundle carries `refs, nodes, trees, commits, schemas` and **no settings**, so a source
  chunking at 8 cloned into a database defaulting to 64 produces trees that can never agree. Nothing
  warned; only the invariant query catches it, and only if you run it.
  `grove.canon_settings()` now travels in every bundle, `unbundle` adopts `chunk_target` when the
  target database is empty (which is what cloning means) and refuses otherwise, naming both values.
  `canon_version`, `hash_algo` and `format_version` always refuse, because no reconciliation of those
  is meaningful. Verified both directions: clone into empty adopts 8 and the tree matches; receive
  into a database at 32 refuses.
  Worth noting how long this hid. `remote_test.sh` has covered clone since the start and passes,
  because it never varies `chunk_target`. The bug needed a *property* test over generated states, not
  another example.
- **the fuzzer could not run twice at once** — `fuzz_test.sh` hardcoded the database `grove_fuzz`, so
  two runs raced on `CREATE DATABASE` and both produced nonsense
  (`duplicate key value violates unique constraint "pg_database_datname_index"`). I did this to myself
  by running `all.sh` while a hunt batch was going, and briefly read the result as a real failure.
  Same defect and same fix as `run.sh` earlier tonight: `grove_fuzz_$$` plus a trap that drops it.
  Two concurrent runs are now both green and leave nothing behind.
- **a round-trip failure that was my own test, and the product was right** — the new round-trip hunt
  started failing at `chunk_target=16` with the clone holding no trees at all, six times in twelve
  runs, while `clone_from` reported no error. The cause was `argument list too long: psql`: at that
  target the fuzzed bundle reaches 2 MB and the test passed it as a shell argument, so psql never
  ran. My error check missed it because the message says "too long", not "error".
  Checked whether real users hit the same wall, because `README` advertises `grove clone pack.json`.
  They do not: `bin/grove` pipes `\set b \`cat file\`` into psql, which never touches argv and has no
  ARG_MAX limit. The test now does the same and 27 consecutive round-trips at chunk 16 are green.
  Two lessons kept. A test that passes a large payload differently from the shipping code is testing
  the wrong thing. And grepping only a summary line loses the seed, which is the same failure mode as
  the `run.sh` summary bug fixed earlier tonight.
- **coverage recorded** — clean so far: ops 400 at rows 2500 across chunk 8/32/64; 3000 operations at
  chunk 64 over 8000 row tables; round-trip at chunk 16/32/64 over 900 row tables, 33 clones total.
  Running: ops 900 at rows 12000 across chunk 8/32/64. Not yet covered anywhere: merges under fuzz.
  The fuzzer branches and checks out but never merges, so three way resolution and octopus have only
  example tests behind them, which is exactly the gap that hid the bundle settings bug.
- **the fuzzer now merges, and it took two attempts to make that mean anything** — 250 operations
  had never once exercised a three way merge. Adding a merge op that picks an existing branch was
  almost worthless: it ran 3 times in 250 operations and every one was a clean merge, because the
  fuzzer's ADD and DROP COLUMN traffic leaves branches with divergent shapes and grove correctly
  refuses to replay across a schema change. 31 of 38 refusals in that run were exactly that.
  The op now *constructs* the conflict instead of hoping for one: branch, edit a text column on the
  branch, come back, edit the same rows differently, commit both sides, merge, then either
  `resolve_all` plus `merge_finish` or `merge_abort`, chosen at random. That yields **10 resolved and
  10 aborted conflicts per 250 operations** instead of zero, and the tree invariant is checked after
  each one. This is the same lesson as the prune op earlier: an operation that executes but cannot
  reach the interesting state is worse than no operation, because it reads as coverage.
  Still not covered: octopus. Its attempts are refused for the same schema-shape reason and logged
  indistinguishably from other refusals, so it needs the same deliberate construction.
- **a batch that was too big to be useful** — ops 900 over 12000 row tables ran for 1h12m without
  finishing the first of three configurations. Killed it. Hunting value comes from many varied runs,
  not one enormous one, and a batch that never reports is indistinguishable from a hung one.
- **octopus is covered now, and getting there was instructive twice over** — the first octopus op
  logged nothing at all, which looked like it was never selected. It was running: grove was
  **correctly refusing** it, with `octopus refuses this merge, 2 of the 3 heads changed
  fz_b(id=323) differently`. My supposedly disjoint moduli 17 and 19 collide at 323, and with 800
  rows that id exists. The refusal was right; my arithmetic was wrong, and the generic exception
  handler had swallowed the evidence into an undifferentiated 'refused' bucket.
  Edits are now disjoint by parity as well as modulus, and the octopus refusal is caught and logged
  separately from other refusals so the two outcomes stay distinguishable. 250 operations now produce
  **10 octopus merges, 10 resolved conflicts, 10 aborted merges and 4 clean merges**, with 24
  multi-parent commits and a maximum of 3 parents, fsck clean.
  The second lesson is about the harness rather than grove: a catch-all `EXCEPTION WHEN others` that
  logs every failure the same way turns a correct refusal and a real bug into the same line. Every
  op that can legitimately be refused should say so in its own words.
- **coverage recorded** — merge campaign clean at chunk 8/32/64, 4 rounds each over 1200 row tables,
  roughly 3600 operations including constructed conflicts. Fuzz surface now includes: insert, update,
  delete, add/drop column, branch, checkout, prune, repack, three way merge with resolution and
  abort, and octopus. Not yet in the fuzzer: rebase, cherry-pick, revert, stash, bisect, tag, notes.
- **what concurrent writers actually do to attribution** — the hazard I flagged while wiring grove into
  a real application turned out to be half as bad as I assumed, and the half that is real was
  undocumented. Alice writes 10 rows and does not commit; Bob edits 3 and commits. **Bob's commit
  claims all 13 rows** and is authored `bob`, because `commit` records every journal row that is not
  yet committed rather than only the caller's.
  But `blame` on one of Alice's rows still says **alice, exact = true**. The journal captures the
  actor per row at write time, so row level attribution survives a commit that mixes authors. That is
  the part an audit depends on, and it holds.
  This is the shared working tree model rather than a defect - `git commit -a` in a shared checkout
  behaves identically - so it is now written down in `LIMITATIONS.md` with the two ways to get
  single-author commits: an advisory lock across write and commit, or committing inside the same
  transaction as the writes, where MVCC hides other sessions' pending rows. 5 assertions in
  `obs_04_concurrent_attribution.sql` pin the behaviour so it cannot drift silently.
  It also settles that the advisory lock in the into-ge wrapper is buying the right thing, and
  buying less than I claimed: without it blame is still correct, only the commit grouping is mixed.
- **the replay verbs are in the fuzzer** — rebase, cherry-pick and revert rewrite history and had only
  example tests behind them. Each now constructs its own scenario rather than waiting for random
  divergence to produce one: revert makes a change, commits it and reverts that commit; cherry-pick
  branches, commits there, returns and picks it; rebase diverges both sides then rebases, aborting if
  it stops on conflicts. Each logs its own refusals rather than sharing the catch-all bucket, which is
  the fix for the mistake that hid octopus.
  300 operations exercise all four paths - cherry-pick 3, revert 1, rebase 1, revert refused 2 - with
  the tree invariant checked after every one. The refusals are my own empty-commit guard correctly
  rejecting the revert of a commit that changed nothing, which is right and is now visible as
  `revert refused` rather than a generic failure.
  Octopus campaign came back clean at chunk 8, 32 and 64, three rounds each over 1000 row tables.
  Fuzz surface now: insert, update, delete, add/drop column, branch, checkout, prune, repack, merge
  with resolve and abort, octopus, revert, cherry-pick, rebase. Still absent: stash, bisect, tag,
  notes, and restore.
- **bisect had one example behind it, now it has an oracle** — the only bisect assertion in the suite
  converged on `c6` in a single fixed 8 commit history. Bisect is precisely the algorithm where
  off-by-one errors hide at the ends, and neither end was covered.
  `bisect_01_oracle.sql` runs every history length from 4 to 9 with the bad value introduced at every
  position from the second commit to the tip: **33 histories**, each bisected to convergence, each
  asserted to land on exactly the commit that introduced it. All 33 pass, including both boundaries,
  so bisect is correct rather than merely untested. No bug found, which is worth stating plainly.
  The test also asserts that both sides of every comparison name a real commit, because an oracle
  that compares two nulls passes for the wrong reason. Two of tonight's false findings came from
  exactly that class of mistake, so it is cheaper to assert non-vacuity than to trust it.
- **three advertised verbs had zero assertions; `renames` now has eight** — counting assertions per
  verb found `stash_push`, `diff_stat` and `table_renames` at **zero**, all three in the README.
  `table_renames` was the likeliest to be wrong, being a content similarity heuristic, so it went
  first. It is correct on every case probed: an exact rename reports `identical` at 1.0; two tables
  renamed in one commit are paired to their own successors rather than cross matched; dropping a
  table and adding an unrelated one reports **no** rename; a rename that also changed a quarter of
  the rows reports `similar` at exactly **0.75**; and the threshold argument includes or excludes
  that pair on either side of it.
  No bug. The value here is that an advertised feature stopped resting on nothing, and the false
  positive case - claiming a rename that did not happen - is the one that would have been actively
  misleading, so it is now pinned.
  Still at zero: `stash_push` and `diff_stat`.
- **the last two advertised verbs with no assertions now have sixteen** — `diff_stat` and
  `stash_push` were both in the README and both tested by nothing. Both are correct.
  The diff stat family is internally consistent, which is the property worth pinning: ten updates,
  one insert and one delete on one table gives `diff_stat` 10 updated / 1 inserted / 1 deleted,
  `diff_numstat` **11 added and 11 removed** because an update counts both ways as it does for a line
  in git, and `diff_shortstat` totals 14 across two tables, which is 11 plus the 3 elsewhere. A
  pathspec narrows it to one table. Nine assertions.
  Stash round trips: push returns a slot and leaves the tree clean with the row back to its committed
  value, the list shows exactly one entry, pop restores the uncommitted work and empties the list, and
  popping an empty stash is refused rather than silently doing nothing. Seven assertions.
  No bugs. Every verb the README advertises now has at least one assertion behind it.
- **calibration corrected** — the replay campaign hit 38 minutes with 15 on a single round, past the
  15 minute rule I had just written down. Each replay op costs a branch, two checkouts and two
  commits, so 400 ops is the wrong number now; the surface changed and the batch size did not follow.
  Killed it. Chunk 8 had already come back green over 400 ops and three rounds.
- **blame has a differential oracle now, and it was proven to have teeth** — blame is the feature two
  of tonight's bugs were in, and it still only had example tests. `blame_03_oracle.sql` builds twelve
  commits that write rotating columns over overlapping row sets, records the last writer of every
  (row, column) pair **in a side table computed by the test rather than by grove**, and then compares
  every pair against `grove.blame`.
  It passes, and more importantly it fails when it should: inverting blame's `ORDER BY a.id DESC` to
  `ASC`, which makes it report the *first* writer of a column instead of the last, turns assertion 3
  red. An oracle nobody has broken on purpose is a guess about coverage, and two of tonight's false
  findings came from exactly that class of mistake.
  It also asserts the comparison spans more than three distinct commits, so it cannot pass by
  comparing one value against itself, and that a column nobody ever updated is credited to the commit
  that first recorded the row.
- **a truncated bundle was accepted, and the clone looked fine** — `SECURITY.md` claimed "every node
  is verified to hash to its own content on receipt, so a tampered bundle is refused, not stored".
  True, and not sufficient. Per-node hashing says nothing about **completeness**: delete half the
  `nodes` array and every remaining node still hashes correctly.
  Measured: a 39 node bundle cut to 19 was accepted, `clone_from` returned success, and the result
  was a database with **942 of 2000 rows** and 20 dangling child references. `fsck` catches it, but
  only if you run it; the clone reports success and looks healthy.
  `unbundle` now checks that every node reference resolves and every recorded tree has a root node
  present, refusing with a count of what is missing. Because it raises inside the caller's
  transaction, nothing is stored, which makes the documented claim literally true rather than
  approximately true. Two assertions in `remote_test.sh`, proven red without the fix: without it the
  bundle is accepted and six nodes are kept.
  The general lesson: integrity of each part is not integrity of the whole, and a security claim
  phrased over parts should be tested against the whole.
- **the malformed bundle seam, probed as a matrix** — rather than one variant at a time, seven were
  generated from one valid bundle and each tried against a fresh clone. Three were accepted that
  should not have been:
  `trees` emptied cloned a table with **0 rows** and fsck clean. `schemas` emptied returned success
  and created **no table at all**. And `settings` removed was accepted silently, which meant the
  canonical-settings check added an hour earlier **could be defeated by deleting the field** - the
  worst of the three, because it turns a guarantee into a suggestion.
  Correct already: reordered nodes and duplicated nodes both clone fine, which is the right answer
  and worth pinning so a future check does not break it. Dangling refs and missing commits were
  refused, but by a raw foreign key violation naming `refs_sha_fkey` rather than by grove, which is a
  poor thing to hand someone holding an untrusted file.
  `unbundle` now requires a settings block, requires every ref to name a commit the bundle carries,
  and requires trees and schemas to pair up per (commit, table). Six assertions, four proven red
  without the fix.
  One mistake of my own on the way, caught by the matrix rather than by me: the pairing check used
  `A EXCEPT B UNION ALL B EXCEPT A` without parentheses. `EXCEPT` and `UNION ALL` share precedence
  and associate left, so it parsed as `((A EXCEPT B) UNION ALL B) EXCEPT A` and only caught one
  direction - `notrees` was refused while `noschemas` still passed. Testing every variant is what
  exposed it; testing the one I had just fixed would not have.
  Also recorded: one roundtrip failure inside `all.sh` that did not reproduce in sixteen further
  runs. Most likely my own file swapping, since proving tests red means copying `sql/install.sql`
  back and forth while roundtrip installs it into fresh databases. Noted as unexplained rather than
  dismissed.
- **a bundle could carry altered rows past every check** — the worst finding of the campaign, and it
  came from asking what the node hash actually covers rather than trusting the sentence in
  `SECURITY.md`.
  A bundle node is `{hash, level, entries}`, and each entry is `{k, h, v}`: the key, the row's hash,
  and the row's **image**. `unbundle` computes the node hash from the `h` fields and compares. The
  `v` field is stored and never checked against its own `h`. So editing a row image while leaving its
  hash alone produces a bundle where **every node still hashes correctly**.
  Demonstrated end to end: `clone_from` returned success, row 212 read `ATTACKER-CONTROLLED` instead
  of `safe-value-212`, and **fsck reported 0 problems**. The claim "every node is verified to hash to
  its own content, so an altered node is rejected" was true of the structure and false of the data.
  Fixed with machinery that already existed rather than new crypto: a tampered image materialises to
  a row whose canonical hash differs, so `clone_from` now rebuilds each table after materialising and
  refuses if it does not reproduce the root the bundle claims.
  Stated rather than glossed: this protects `clone_from`, which materialises. `receive` and `fetch`
  do not materialise, so images taken through them are unproved until checkout. `SECURITY.md` now
  says exactly that and gives the invariant query to run after receiving from an untrusted source.
  The general shape, for the third time in this campaign: a hash proves what it covers and nothing
  else, and the interesting question is always what sits just outside it.
- **commit history was forgeable in a bundle** — worse than the row-image bug, and found by the same
  question: what does this hash actually cover, and what verifies it?
  `grove.commit_sha` covers parent, author, message, timestamp and the roots of the commit's trees.
  It is called in `commit` and `merge_finish` and **nowhere in `unbundle`**. So a received commit's
  sha was never checked against its own content. Rewriting every commit's author to
  `trusted-reviewer` and message to `Approved by security team`, keeping the shas, produced a clone
  where `grove.log()` displayed the forged history and **fsck reported 0 problems**. For a system
  whose product is an audit trail, that is the whole product gone.
  `unbundle` now recomputes each commit's sha from its content and refuses on mismatch, handling
  octopus commits through `octopus_commit_sha` with their full parent list. A bonus from the same
  check: repointing a commit's tree root is also caught now, because the summary the sha covers
  includes the roots.
  Probed and found already safe: a tip schema naming an unknown type is caught by `checked_type`, and
  a renamed column in a tip schema is caught by the row-image verification added earlier, because the
  canonical row form changes and the rebuilt tree stops matching.
  Three bugs in this class now share one shape. A hash existed, it covered the right thing, and
  nothing checked the content against it on the way in.
- **the row-image fix only covered one of the three doors.** The previous fix put the rebuild-and-compare
  in `clone_from`, because clone is where images become rows. But `fetch` and `receive` reach the same
  store without materialising anything, and SECURITY.md documented that gap as a limitation with a
  manual query as the workaround. A documented hole is still a hole. Fetching a bundle whose row 7 read
  `HACKED / 999999` into a repo with existing history, then checking the branch out, put those values in
  the table and `fsck` reported 0 problems.
  The fix belongs at the funnel, not at one exit: `unbundle` now recomputes every row's hash from the
  image the bundle carries, using the column shape recorded for that commit, and refuses before storing
  anything. `grove.verify_images(root, cols)` walks the tree with `grove.leaves` and hashes the images
  in one dynamic query per tree rather than one per row.
  Two details that would have been quiet bugs: the column ordering has to be `COLLATE "C"` to match
  `ORDER BY attname` on Postgres's `name` type, or a table with a `user_id`/`userid` pair would be
  refused for no reason; and a column type the receiving database does not have is now an explicit
  refusal rather than a skipped check, so a bundle cannot opt out of verification by naming a type
  nobody has.
  The `clone_from` rebuild stays, demoted: it no longer catches tampering, it catches materialisation
  going wrong.
  Worth naming the pattern, because it is now four for four: every one of these bugs was a hash that
  covered the right thing with nothing checking the content against it, and this one adds a second
  lesson, that fixing such a check at one call site leaves the others open.
- **a forged schema fingerprint walked past the shape guard.** `checkout` refuses to restore rows into a
  table whose shape has changed, and it decides that by comparing `grove.schemas.fingerprint` against
  the live table's. The fingerprint is `hash(columns)` and nothing checked it against the columns
  stored right beside it. A bundle carrying an honest column list next to a fingerprint copied from
  the victim's own table sailed through: 300 rows restored into a four-column table, the local
  `secret` column blanked on every row, HEAD pointing at the commit, `write_tree` disagreeing with
  the recorded root, and `fsck` reporting 0 problems. `unbundle` now recomputes every fingerprint
  from its own columns.
  Probed in the same pass and already safe: `pk_cols` repointed at a different real column is caught,
  because the tree's keys come from the primary key and the restored table stops reproducing the
  root; and a `pk_cols` naming a column that does not exist dies in `CREATE TABLE`. The first of
  those is caught by the `clone_from` rebuild demoted in the previous commit, which is a good
  argument for having kept it, so it now has a test of its own.
  This is the fifth bug of one shape and the second sub-shape: not only "a hash nothing checks", but
  "a derived value nothing re-derives". Anything stored next to the thing it is computed from is a
  place to look.
- **fsck audited the shape of the store and never re-derived anything from content.** Built a differential
  oracle: corrupt a healthy repository one way at a time by direct SQL, confirm the corruption really
  landed, then ask fsck. Six corruptions were invisible, and the first run of the oracle was itself
  vacuous, two probes had been silently rejected by foreign keys and I was reading zeros as "fsck
  missed it" when the corruption never applied. Worth remembering: an oracle needs its own
  non-vacuity check.
  Invisible: an edited row image, a rewritten commit author and message, a backdated commit, a forged
  schema fingerprint, a tree left behind by a commit that is gone, and rewritten `pk_cols`. fsck now
  recomputes every commit sha, re-derives every fingerprint from its own columns, re-hashes every
  stored row image, and reports trees whose commit is not in the store. `pk_cols` is left alone: there
  is nothing local to re-derive it from, since a primary key may legitimately have changed.
- **prune quietly made every pruned repository unclonable.** This one only surfaced because the new fsck
  check failed an existing test. `prune` severs history by setting `parent_sha = NULL` on the cutoff
  commit and deleting its extra parent rows, while keeping its sha, so that commit provably stopped
  hashing to its own content. Nothing noticed until today. Then the commit-sha verification added
  earlier in this campaign turned it into a hard failure: a pruned repository could not be cloned or
  pushed at all, and the error blamed the transport ("rewritten in transit") for damage done locally.
  Fixed the cause rather than the symptom. `grove.shallow` records the parent list prune severs, the
  bundle carries it, and `grove.recomputed_commit_sha` uses it, so a truncated history still verifies
  against what it was. This is how git's shallow clones work: the graft boundary is recorded, not
  forgotten.
  The verification and fsck now share that one function, which is the actual lesson. There were three
  copies of "what does a commit hash to" (commit, unbundle, fsck) and the drift between them is what
  the whole class of bugs is made of.
  A note on cost: the first version of the image check walked every tree of every commit, which is
  quadratic in history, and it pushed the suite past ten minutes. It now verifies each distinct leaf
  node once via `grove.reachable_nodes`, which is proportional to the store rather than to history
  times the store. 41 commits over 3000 rows: 183 ms.
- **a column called `value` broke unbundle and fsck on the real schema.** Caught by the realworld suite,
  not by design. The dynamic query built to verify row images put `jsonb_array_elements`'s own `value`
  column in the same scope as the row's columns, so any tracked table with a `value` column produced
  `column reference "value" is ambiguous` and failed outright. Nothing adversarial, just an ordinary
  column name. Every synthetic test in the suite used `id`, `name` and `price`.
  Qualifying my own reference was not enough, because the ambiguity comes from the row side, where the
  canonical expression names columns unqualified. The fix reuses `"grove img"`, a name `grove.track`
  already refuses to let a tracked table use alongside `"grove row"`, so there is no third reserved
  word and the existing guard covers it.
  `security_02_hostile_bundle_columns.sql` now tracks a table with columns named `value`, `h`, `v`,
  `select` and `grove entry`. The lesson is about test data, not about SQL: run new code against the
  real dump early, because a synthetic schema agrees with whatever assumptions the code was written
  under.
- **a bundle could pad the receiver's store with data nothing can reach.** The resource-exhaustion lead
  turned out to be a dead end in its original form: unbundle is linear in bundle size, 0.8s, 1.5s and
  2.9s for 1370, 2630 and 5326 nodes, so there is no superlinear blowup to exploit. The interesting
  version was next door. `unbundle` stored every node a bundle carried whether or not anything
  referenced it, so appending valid nodes lifted from an unrelated repository turned a 28 KB bundle
  into 2.1 MB, and the receiver stored 69 nodes it could never use, with fsck reporting clean.
  `grove.bundle` sends exactly `reachable_nodes(roots)` minus what the receiver already has, so
  refusing unreachable nodes cannot produce a false positive by construction.
  Placement mattered more than the check. Put before the structural checks it fired first on two
  existing malformed-bundle cases and gave a worse diagnosis than the one they assert: a bundle with
  no trees is better described as missing its trees than as carrying unreachable nodes, and a
  repointed tree root is better described by the commit sha not covering it. Padding is the weakest
  signal, so it runs last. A refusal that names the wrong cause is only half a refusal.
- **a row could be filed under a key that was not its own.** The node hash covers the row hashes ordered
  by key. It does not cover the keys. So changing a key while preserving sort order left every hash
  intact, and nothing else re-derived the key from the row beside it. Verified by differential, an
  honest fetch against a re-keyed one: `blame` on the affected row returned 2 rows in the control and
  0 in the tampered repository, and the *next* commit produced a tree that no longer matched the live
  table, while fsck reported clean at every step. Silent corruption arriving one commit later than
  the tampering, which is the worst shape a bug can have.
  The key is a derived value like the fingerprint was: it is the canonical primary key of the row
  image sitting next to it. `grove.verify_keys` re-derives it, in `unbundle` and in `fsck`.
  The first attempt at this probe was vacuous, I guessed the key format was a plain integer and
  changed nothing, then read the resulting successful clone as evidence of a hole. The keys are
  hex-encoded canonical primary key text. Always print the thing before mutating it.
  A side effect worth having: a bundle that repoints a table's primary key is now refused at unbundle
  with the precise reason, rather than after materialising with the vaguer complaint that the rows do
  not hash to the tree.
- **the primary key had two sources of truth, and they drifted.** `grove.schema_columns` records names and
  types, so a table's shape fingerprint does not cover its primary key. Change the key without
  touching the columns and the shape guard sees nothing. Meanwhile the tree's keys come from
  `pk_canon_expr`, which reads the live index, while `grove.tracked.pk_cols` is captured once at track
  time and never refreshed, and the journal triggers use that stale copy.
  Result: after `ALTER TABLE t DROP CONSTRAINT t_pkey; ADD PRIMARY KEY (b)`, a commit succeeded, the
  tree was keyed by `b`, the recorded shape claimed the key was `a`, and the journal was still keying
  by `a`. The repository could no longer be bundled at all, refused by the key check added in the
  previous commit. Same shape as the prune bug: an ordinary local operation quietly produces a
  repository that cannot be cloned.
  Committing now refuses while the two disagree and says to re-track. Re-tracking adopts the new key,
  the commit goes through, fsck is clean and the repository clones again with every row. fsck reports
  the drift by name rather than only its downstream symptom.
  What I predicted was data loss from duplicate keys, and that was wrong: the tree keyed by the live
  key, so no rows collided. The bug was one layer over, in what the commit recorded about itself.
- **retuning a documented knob wedged the repository.** `chunk_target` is listed in ARCHITECTURE.md as a
  tunable. Change it after committing and the repository could no longer be checked out *or*
  committed: `is_dirty()` said there were uncommitted changes, `commit` said there was nothing to
  commit, and both were reporting honestly about different things. `is_dirty` did a full rebuild with
  `write_tree`, which re-chunks under the new target, while `commit` builds incrementally from the
  parent, which preserves the old chunk boundaries. Identical data, two different trees, no way out
  except guessing the old value.
  The same lesson a fifth time: two definitions of one question. `grove.nothing_to_commit` is now the
  single answer to "is there anything to record", and both `commit` and `is_dirty` call it.
  A second disagreement fell out of the same change, in the other direction: changing a row and
  changing it back left journal rows, so a journal-based `is_dirty` would have called that dirty while
  `commit` refused it. Sharing commit's own test handles both, which is the argument for sharing
  rather than reimplementing.
  The test asserts non-vacuity explicitly, that a full rebuild really does move the root after the
  retune, otherwise "not dirty" would prove nothing.
- **two settings described the code without controlling it.** `hash_algo` and `canon_version` are seeded
  once and read in exactly one place, `canon_settings`, which puts them in every bundle. Nothing else
  reads them: `grove.hash` is sha256 outright and the canonical expressions have no version switch.
  So setting `hash_algo` to sha512 changed nothing at all, same root, same 32 byte digest, while every
  bundle then claimed sha512 and honest repositories refused a byte-identical history over a
  difference that did not exist. The failure mode runs the other way too: two repositories both
  mislabelled interoperate happily while believing they agree on something they never checked.
  Writing a value the build does not implement is refused now, so the label cannot drift from the
  behaviour. When a second algorithm or canonical form is actually implemented, the allowed set grows
  with it, which is the point: the guard is a reminder that the setting is a promise.
  Same family as the rest, seen from the other side. Every earlier one was a value derived from
  something nobody re-derived it from. This is a value that describes something nobody compares it
  against.
- **the strategy knobs are sound, and now there is an oracle saying so.** Asked whether any user-settable
  value can produce a *wrong* tree rather than just a slow one. `max_incremental_keys`,
  `splice_max_changes_per_chunk` and `rebuild_when_hit_fraction` choose how the incremental build gets
  there; only `chunk_target` should change where it arrives. 80 combinations over 3000 rows with
  updates, deletes and inserts pending: every one reached the same root as a full rebuild. Negative
  and out-of-range values too, they only pick a path. Values the code cannot honour raise instead:
  `max_tree_depth = 0` gives "tree depth exceeded at level 1", a non-numeric value fails the cast.
  No bug, so the result is now `settings_03_strategy_knobs_agree.sql`, a 27-combination matrix with an
  explicit non-vacuity assertion that the pending edits really moved the tree. This is the invariant
  most likely to be broken by a future optimisation of the incremental path, and until now the suite
  checked two combinations of it.
- **renaming a tracked table strands earlier history, and I got the fix wrong first.** The oid in
  `grove.tracked` follows a rename while the text name in `grove.trees` does not, which looked like
  another two-sources-of-truth bug, so I made `commit` refuse and had `fsck` report it. The suite said
  no: `renames_01_detection.sql` renames two tracked tables, commits, and expects
  `grove.table_renames` to pair them. Renaming is a designed feature and my guard contradicted it.
  Reverted.
  What is actually broken is narrower. Commits before the rename name `t`, commits after name `u`, and
  checking out across that boundary needs both names to exist at once, which a rename cannot give you.
  Established by running it rather than reasoning about it: renaming back is not enough either,
  because then the commit being left behind names the other one. With `t` restored and an empty `u`
  created, the checkout runs and brings all 200 rows back.
  So the fix is a diagnosis, not a guard: `checkout` names the table it is missing, on both sides of
  the move, instead of failing with a bare `relation "t" does not exist` from inside the diff. Written
  up in LIMITATIONS.md, including that fixing it properly needs a stable table identity in
  `grove.trees` instead of a text name, which changes the bundle format.
  Worth keeping in mind: the codebase told me my first fix was wrong within one test run. Reading the
  existing tests for a feature before guarding against it would have been quicker.
- **untracking a table scheduled its data for deletion.** `untrack` means stop versioning this table.
  What it actually meant was: the next commit drops the table from the history, `diff_stat` reads that
  as all 100 rows deleted, and the next `checkout` applies that deletion to the live table. A table
  grove had been explicitly told to leave alone was emptied by switching branches, with fsck clean
  throughout. Found by asking what happens to recorded history when the live state changes, the same
  question that produced the key drift and rename findings.
  The cause is in the table selection, not in the diff: five loops across `revert`, `checkout`, `merge`
  and the replay path all iterate `grove.trees` for the relevant commits and write to whatever they
  find, without asking whether the table is still tracked. `grove.replay_tables` is now the one place
  that answers "which tables may this replay write to", and all five use it.
  The rule it encodes is worth stating plainly: grove writes only to tables it is tracking. The test
  pins both directions, an untracked table is neither emptied nor restored.
  Non-vacuity mattered here: the test asserts the older commit still records the table and that the
  diff still reads it as 100 deletions, so the passes afterwards mean the replay declined to act
  rather than having nothing to act on.
- **revert is the one replay path with no schema assertion, and nothing tested what saves it.** checkout,
  merge, cherry-pick and octopus all call `assert_live_schema` or `assert_same_schema`. `revert` calls
  neither, so on paper it can replay row images from before a column existed into the table as it is
  now. In practice it refuses, because adding a column changes every row's canonical hash, so its
  conflict pre-check sees the rows as changed since the commit and stops. The protection is real but
  incidental, and `grep` found no test anywhere for "refusing to revert".
  Resisted the urge to add an assertion. `assert_live_schema` compares fingerprints, so it would also
  refuse a widening like int to bigint, which changes the fingerprint but not the canonical form and
  reverts correctly today. That would turn working behaviour into a refusal, which is a regression
  wearing a fix's clothes.
  What was missing was the test. `replay_08_revert_refusals.sql` pins all three: a clean revert
  succeeds, a row edited by hand since stops it with nothing applied on the way, and a commit from
  before an added column is refused so the column is not blanked by replaying old images. The first
  assertion exists to keep the other two from passing vacuously.
- **built a coverage oracle over the guards themselves, then had to fix the oracle twice.** revert's
  load-bearing check turned out to be untested, so the obvious question is which others are. Extracted
  every `RAISE EXCEPTION` message from sql/install.sql and matched their literal fragments against
  everything under test/. First run claimed 64 of 72 untested, which was nonsense, my matcher took the
  longest fragment and missed the phrases the tests actually assert on. Validated the second version
  against six messages I knew were asserted before trusting a single negative: 16 of 72 have no
  assertion anywhere.
  Most are argument validation. The load-bearing ones are in the merge finish path, so I probed those:
  finishing with conflicts outstanding is refused, a branch that moved under the merge is refused, an
  unknown merge id is refused, and the merge completes once the branch is back. All correct, none
  tested. `merge_10_finish_guards.sql` pins them.
  The test itself passed standalone and failed inside the suite, which is the part worth writing down.
  `grove.merge` returns the *conflict count*, not the merge id, and in a fresh database both were 1.
  Running the suite in order advances the merge sequence and the coincidence breaks. A test that passes
  because two unrelated numbers happen to be equal is exactly the failure the non-vacuity habit is for,
  and it took the suite's own ordering to expose it.
- **every refusal in the codebase is now asserted somewhere.** Took the remaining thirteen untested
  guards from the coverage oracle and probed each one before writing a line of test, on the theory
  that an untested guard might be unreachable or broken. All thirteen fire correctly: branching before
  the first commit, popping an empty stash, an unknown branch, a sha matching nothing, a bad access
  level, a bad reset mode, a bad bulk or single resolution, a custom resolution with no row image,
  resolving a conflict that is not there, reverting a commit not in the store, creating a table the
  commit has no shape for, and tagging something that does not resolve. No bug, so they are pinned in
  `guards_01_refusals.sql`, with an assertion that the merge really conflicted so the resolution
  guards are not aimed at nothing.
  Re-running the oracle afterwards reports one message left, and that one is a false negative: the
  test does assert it, but `grove: no merge % in progress` splits into fragments too short for the
  matcher's fourteen-character window. Worth writing down so the next person does not chase it. The
  honest count is 72 of 72.
- **the access lists had drifted, and the revoke that enforces them ran too early.** Two findings from
  one probe, both the hand-maintained-list shape. `grant_level` grants a role execute on every grove
  function except those named in `write_verbs()` or `admin_only_verbs()`. Derived the set of functions
  that actually write from `pg_proc.prosrc` and compared: `resolve_conflict` was missing beside
  `resolve_all`, `fetch` beside `receive`, `grant_level` beside the three wrappers that call it, and
  `virtual_merge` beside the other internals. Every omission has a sibling already listed, which is
  what makes it oversight rather than design.
  Then the sharper one. `REVOKE ALL ON ALL FUNCTIONS FROM PUBLIC` sits at line 4643 and ten functions
  are defined after it, so those kept PostgreSQL's default public execute grant no matter what the
  lists say. A read role had execute on `grant_level` and `log_rotate`, both admin-only, confirmed
  with `has_function_privilege`. The revoke now runs after every definition.
  Honest severity: not a privilege escalation. There are no SECURITY DEFINER functions, table grants
  are the real boundary, and I verified a read role gained no insert, update or delete anywhere and
  that `log_rotate` died on the events table. What was broken was defence in depth and the intent the
  lists express.
  The test derives the writer set rather than listing names, so the lists cannot drift again, and it
  asserts a read role can still execute the reading functions so the zero it checks for means
  something.
- **upgrading broke every role that already had access.** Every suite installs into a fresh database, so
  nothing ever ran `install.sql` twice over the same one, even though reinstalling is the documented
  way to upgrade. It loses grants. Twenty-four `DROP FUNCTION IF EXISTS` statements sit in the file for
  signatures that changed, and a dropped function takes its grants with it, while `CREATE OR REPLACE`
  keeps them. A write role went from 170 executable functions to 161 and could no longer commit,
  failing with "permission denied for function snapshot_trees" from line 21 of `commit`. Nine
  functions, silently, on every upgrade.
  The level a role was granted was recorded nowhere, so nothing could put it back. `grove.access` now
  holds it and a block at the end of install re-applies it for roles that still exist, after the
  revokes rather than before. Same family as the rest: a fact that lived only in the catalog, with no
  way to re-derive it.
  Two self-inflicted detours worth noting. The first attempt used `ON CONFLICT (role_name)`, which
  cannot be qualified, so it collided with the parameter of the same name and broke `grant_level`
  outright, and my probe reported zero rather than an error. Delete then insert avoids it. The second
  is that my first measurement of the whole problem was vacuous: the privilege query had an ambiguous
  `oid` and returned blank both before and after, which reads exactly like "nothing changed".
  `upgrade_test.sh` is a new suite because pgTAP cannot reinstall inside a transaction. Four of its ten
  assertions fail without the fix.
- **repeated prune and clone cycles hold up, and now something checks that.** Following the question the
  upgrade bug raised, what does the suite never do that a user does, the answer after "start from an
  existing database" is "start from a repository that has already been through this once". Every clone
  test clones a fresh origin exactly once. So: prune the origin, clone it, commit in the clone, prune
  that, clone onward, commit again. Nothing breaks. The second hop's table is byte-identical to its
  source by md5, rebuilds the same root, carries a boundary of its own, commits, and passes fsck.
  No bug, so it is pinned in remote_test.sh. It matters because it is the only test that exercises the
  shallow boundary being created, carried across a bundle, and then created again on top of one that
  arrived from somewhere else, which is exactly the state the prune fix earlier in this campaign
  introduced.
- **a grove database survives pg_dump and pg_restore, and now something says so.** The strongest remaining
  guess under "what does the suite never do" was a dump and restore, because `grove.tracked.tbl` is a
  `regclass` and oids change on restore. It holds: pg_dump writes regclass values by name, so they
  resolve to the new oids, and the journal triggers are dumped with the tables they sit on.
  Checked the whole way through rather than stopping at "it restored": eight triggers present, a change
  made afterwards lands in the journal, it commits, the table matches the tree that commit recorded, a
  branch made before the dump checks out and puts the old value back, fsck is clean, and the restored
  database can still be cloned from. Thirteen assertions in a new `dump_restore_test.sh`.
  No bug. Worth having anyway: backup, restore and moving to another server is a thing users do and
  nothing exercised it, which is exactly the category the upgrade defect came from.
- **the docs claimed composite primary keys were handled, and three verbs disagree.** Most tests use a
  single int `id`, so the key-encoding paths only ever saw one column. Ran a composite key through the
  whole workflow instead: track, commit, journal, diff, tree, fsck, a merge that conflicts, resolve,
  finish, bundle and clone. All correct. Keys encode as `region=#2:r1|sku=#4:sku6|`, the journal
  identifies rows by both columns, the conflict names the row in canonical form, and the clone is
  identical to its source by md5.
  But `blame`, `log` with a `table:row` pathspec and `restore` with a `table:row` pathspec all refuse:
  they take one key value as text and will not guess how to split it. LIMITATIONS.md listed composite
  primary keys under what grove handles, with no mention of the exception. That is the same family as
  the unenforced settings, documentation asserting behaviour nothing compares against the code.
  Corrected the docs rather than inventing a key syntax on my own initiative, and pinned both halves
  in a test so they cannot drift apart again.
  One detail found by the test failing: `restore`'s refusal is data-dependent. It only reaches the key
  check when there is a differing row, so restoring one row of a composite-key table returns zero
  when there is nothing to do and refuses when there is. My first version of the assertion set up no
  difference and so passed through the guard without touching it. Recorded in the docs.
- **the recorded table name depended on the session's search_path.** PostgreSQL renders a table name
  relative to `search_path`, so the same table is `t` from one session and `public.t` from another,
  and grove stored that rendering in `grove.trees`, `grove.schemas` and compared against it later by
  text. A repository committed with a qualified name reported itself dirty from an ordinary session
  with nothing changed, refused nothing as empty, and worst of all `checkout` ran, returned success,
  and restored nothing, because `replay_tables` found no table whose rendered name matched.
  Fixed by making the name sticky: `grove.recorded_name` looks up what the parent commit called this
  table and reuses it, so identity is fixed at the first commit rather than re-derived per session,
  and every place that matches history to a live table resolves the recorded name with `to_regclass`
  instead of comparing text. Five joins in total, in `snapshot_trees`, `nothing_to_commit`,
  `replay_tables`, the working-tree diff and the stash path.
  Deliberately not fixed: rewriting old repositories to store qualified names. The table name is part
  of the commit summary that `commit_sha` covers, so changing it would invalidate every commit sha in
  the repository. A name that never resolved from this session still cannot, and `checkout` says which
  one it wants. Written up in LIMITATIONS.md.
  My first test passed against the unfixed code, which meant it reproduced nothing: both sessions were
  the same session, so both renderings agreed. The rewrite records from a session with `search_path =
  pg_catalog` and asserts from the default one, and the second assertion pins the divergence itself so
  the case cannot quietly stop being a case.

## Reference

`docs/ARCHITECTURE.md` for how the layers fit together, `docs/LIMITATIONS.md` for what this
deliberately does not do, `PERF.md` for every measurement including the nine that came out worse.
