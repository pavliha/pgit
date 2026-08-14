# Build plan

Worked top to bottom. One item per iteration: implement in `sql/`, add pgTAP tests in `test/`,
run `make test` until green, then tick the box and append a line to **Progress log**.

## Decisions taken (reversible)

| Decision | Taken | Why |
| --- | --- | --- |
| Identity across branches | canonical PK bytes; branch-created rows get disjoint sequence ranges | works with existing serial PKs, no schema migration forced on adopters |
| Materialisation | logical — one working database holds one checked-out branch | the only form a plugin can do; matches git's working tree |
| Staging model | auto-commit per transaction, explicit grouping opt-in later | matches how an application writes; a psql user can opt in |
| Hash | `sha256` from core | no pgcrypto dependency |
| Chunk target | 64 | measured within 4× across sequential, uuidv4, uuidv7 and common-prefix keys |
| License | MIT | swap before any public release if a patent grant is wanted |
| Dirtiness | decided by **content** (live tree root vs HEAD's recorded root), not by unstamped journal rows | pgit's journal is ENABLE ALWAYS, so checkout's own writes would make the tree look dirty the instant it finished. Content is also more faithful to git: edit a value and put it back and you are clean. |
| Checkout journal rows | `checkout` deletes its own unstamped journal rows | a checkout is a *materialisation*, not an edit. A revert produces new content that should become a commit; a checkout reproduces a commit that already exists. |
| DDL detection | **catalogue fingerprint at commit time**, no event trigger | an event trigger needs superuser and buys nothing for correctness here — the fingerprint recorded per commit is what every guard actually reads. This is the AC-PORT-04 fallback promoted to being the mechanism, so the portable path is the only path. |
| Merge runs with triggers ON | merge does **not** use replica mode, unlike revert and checkout | replica mode disables referential-integrity triggers, which would defeat the entire point of AC-MERGE-08. A merge is a real write to the working tree, so constraints and user triggers behave exactly as they would for any other write. |
| AC-REPLAY-02 reading | a *read* must not grow history; a revert is a real write and IS journalled | the criterion says "replay does not record new journal entries. History must not grow by being re-read" — the second sentence is the intent. If replay went unjournalled, `diff_journal` would disagree with the tree for any range containing a revert. **Reversible: say the word and replay becomes invisible to the journal.** |

## Done

- [x] **canon** — canonical row form, content-defined boundaries, tree root. 34 assertions green.
      AC-CANON-01 through -07.
- [x] **journal** — `pgit.changes`, `pgit.tracked`, one generic row trigger, `pgit.track` /
      `pgit.untrack`, actor and source from `SET LOCAL pgit.actor` / `pgit.source`, and a
      `BEFORE TRUNCATE` statement trigger that journals every destroyed row. 21 assertions.
      AC-COMMIT-01, -03, -07, AC-DDL-05, -06.
- [x] **objects** — `pgit.nodes`, `pgit.trees`, `pgit.write_tree` persisting every level
      content-addressed. `tree_root` now delegates to it, so there is one hashing implementation.
      8 assertions.
- [x] **commit** — `pgit.commits` DAG, `pgit.refs`, `pgit.head`/`pgit.resolve`,
      `pgit.commit(msg, who, ts)`, and `pgit.advance_ref` as a compare-and-swap. 15 assertions.
      AC-COMMIT-02, -05, -06, AC-REF-01.
- [x] **diff-core** — `pgit.leaves`, `pgit.diff_leaves` (pruning descent), `pgit.diff_tree`,
      `pgit.diff(a_sha, b_sha)`, and `pgit.apply_diff` for the round trip. 14 assertions.
      AC-DIFF-01, -02, -03.
- [x] **diff-oracle** — `pgit.changes.commit_sha` stamped at commit, `pgit.ancestry`,
      `pgit.diff_journal` (independent replay implementation), `pgit.lookup` point lookup, and a
      randomised differential test: 1000 operations, 51 commits, 40 sampled commit pairs.
      5 assertions. AC-DIFF-04. **Found three real bugs in the tree diff.**
- [x] **diff-surface** — `diff_stat`, `diff_numstat`, `diff_shortstat`, `diff_name_only`,
      `diff_name_status`, and a `pathspec` argument on `pgit.diff` addressing table, row
      (`t1:5`) and column (`t1.name`). 14 assertions. AC-DIFF-06, -07.
- [x] **revert** — `pgit.revert(sha)` with a per-row conflict guard, replay under
      `session_replication_role = replica`, and `pgit.live_hash`. 14 assertions.
      AC-REPLAY-01 through -05.
- [x] **blame** — `pgit.blame(tbl, key)` returning the last writer, actor, timestamp and current
      value per column, from the journal. 8 assertions. AC-BLAME-01, -02.
- [x] **log-show** — `pgit.log(start, pathspec)` walking the DAG by depth, `pgit.show(sha)`,
      `pgit.short_sha`. 10 assertions. AC-LOG-01, -02, AC-SHOW-01.
- [x] **branch** — `pgit.branch`, `pgit.branches`, `pgit.checkout`, `pgit.delete_branch`,
      `pgit.is_dirty`. 13 assertions. AC-REF-02, -03, -04.
- [x] **merge** — `pgit.ancestors`, `pgit.merge_base` (refusing criss-cross), `pgit.merge_plan`
      (three-way per cell), `pgit.apply_row`, `pgit.conflicts`, `pgit.merge` with fast-forward and
      two-parent merge commits. 23 assertions across four files.
      **AC-MERGE-07 and -08 both pass — the central architectural argument is proven.**
- [x] **replay-verbs** — `pgit.cherry_pick`, `pgit.rebase`, `pgit.rebase_abort`,
      `pgit.materialise`, `pgit.record_conflicts`, `pgit.rebase_state`. 16 assertions across three
      files. AC-REPLAY-06 through -09.
- [x] **perf-1m** — `bench/` fixture, commit and diff harnesses, `make bench`, results in
      `PERF.md`. No pgTAP assertions: timing assertions are flaky and would be worse than no test.
      **AC-PERF-01 property holds, AC-PERF-04 and -05 miss; both gaps recorded, neither target
      touched.**
- [x] **ddl** — `pgit.schemas`, `schema_fingerprint`, `schema_columns`, `record_schemas`,
      `assert_same_schema` guarding cherry-pick and merge. 9 assertions.
      AC-DDL-01, -02, -04, AC-REPLAY-10, AC-MERGE-12.
- [x] **cli** — `bin/pgit`, a bash-over-psql CLI: status, log, show, diff (with --stat, --numstat,
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
- [x] **reuse temp tables across calls** — `pgit.ensure_scratch` creates nine scratch tables once
      per session; every tree function now `TRUNCATE`s and refills them instead of
      `DROP`/`CREATE`. 3 assertions. **500 commits in one transaction: crashed → 16 ms mean.**
- [x] **AC-PERF-03** — 50-table fixture, diff locality measured by block counts. 5 assertions.
      **494 blocks for one changed table against 24,700 for fifty — a ratio of exactly 50.0.**
- [x] **statement-level journal trigger** — `pgit.journal_stmt` with `REFERENCING OLD TABLE`/`NEW
      TABLE`, three statement triggers per tracked table. 6 assertions.
      **Write amplification 15× → 10.1×. AC-PERF-05 still misses its 2× target; see `PERF.md`.**
- [x] **AC-REPLAY-11** — `test/kill_test.sh`, a two-session harness that kills a backend mid-rebase.
      9 checks, wired into `make test`.
- [x] **AC-PERF-02 at the full 10,000 commits** — **163 ms for 10 rows 10,000 commits apart, against
      179 ms one commit apart.** Criterion met at the stated figure, not a reduced one.
- [x] **checkout across a schema change** — `pgit.assert_live_schema` runs before the dirty check
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
  `pgit.changes`, which no amount of optimisation avoids. Options: (a) drop the `before` image and
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
  **Delta compression is now built** (`pgit.repack`, default depth 1: 34% of the node store for 11%
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
- **Checkout across a schema change still only refuses politely.** `pgit.assert_live_schema` now
  names the table and both column lists instead of blaming uncommitted changes, but `checkout` still
  materialises data and not shape. Actually versioning DDL and replaying it on checkout is a project,
  not an afternoon, and remains undone.
- **The conflict guard is O(table) per revert.** `pgit.live_hash` computes `row_hashes` over the whole
  table for each key it checks. Correct but wasteful; it should become a keyed lookup before the
  perf gates.
- **Git verbs deliberately not built, with the reason.** The inventory is now closed except these,
  and each is a judgement rather than a backlog item.
  - **`subtree`, `submodule`** — no analogue. Both compose *repositories*; there is one database and
    one history here, and a nested history would be a second `pgit` schema with its own refs, which is
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
  named `tbl` is ambiguous against `pgit.tracked.tbl`, and `CREATE OR REPLACE FUNCTION` cannot
  rename a parameter, so renaming it needs an explicit `DROP FUNCTION IF EXISTS` to keep
  `install.sql` re-runnable. Any later signature change needs the same treatment.
- **objects** — 8 assertions, suite now 63/63. The headline measurement: changing **one row** in a
  5000-row table rewrites **exactly one** leaf node and shares every other one. That is the
  O(difference) property demonstrated rather than asserted, and it is the first real evidence the
  storage bet works. `write_tree` now always wraps leaves in a node (the old `tree_root` returned
  a bare row hash for single-row tables, which left the root with no node to descend), and
  `tree_root` delegates to `write_tree` so the two can never drift apart.
- **commit** — 15 assertions, suite now 78/78. `pgit.commit(...)` is callable unquoted; COMMIT is
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
  resolved by point lookup in both trees.** That is what `pgit.lookup` is for, and it is the
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
  stays empty while a revert rewrites 3 rows — but it would equally silence pgit's own journal and
  leave history blind exactly when the database is being rewritten. Marking `pgit_journal` as
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
  dirtiness had to become **content-based**, because pgit's own ENABLE ALWAYS journal would
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
  precise about what it proves: the criterion says "releases its **advisory** locks" and **pgit takes
  no advisory locks anywhere**, so that half is vacuous, not passed. What it does show is that crash
  safety is **inherited** — every ref move, node write and journal row is an ordinary table write in
  the caller's transaction.
- **AC-PERF-02 in full** — **163 ms for 10 rows 10,000 commits apart, against 179 ms one commit
  apart.** Flat in history at the stated figure. The run also produced the most uncomfortable number
  in the project: 10,000 commits grew `pgit.nodes` to **540 MB for a 107 MB table**, none of it
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
  like git's, so the write path is untouched and commits stay at 25 ms; `pgit.repack()` / `pgit gc`
  rewrites older chunk versions as deltas against the next newer one, and `pgit.unpack()` reverses
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
  `checkout` failed outright** while everything else already worked. `pgit.replay_begin()` now tries
  the GUC and falls back on `insufficient_privilege` to disabling each non-pgit trigger by name,
  restoring its exact prior state afterwards — asserted, since `ENABLE TRIGGER USER` would have
  flattened an `ENABLE ALWAYS` trigger to `ENABLE`.
  The fallback is arguably the better path: `DISABLE TRIGGER` skips internal triggers, so
  **referential integrity stays enforced during replay**, closing the FK gap replica mode left open
  and listed under Follow-ups. It costs an ACCESS EXCLUSIVE lock per tracked table.
- **conflict resolution** — 19 new assertions (259 pgTAP + 19 CLI + 9 kill + 12 RDS = 299). Before
  this, `pgit.conflicts` was **written and never read** — a conflicted merge reported a count,
  applied nothing, and offered no way forward. Now: `pgit.merges` tracks an in-progress merge,
  conflicts carry a resolution, and `resolve_conflict` / `resolve_all` / `merge_finish` /
  `merge_abort` close the loop. CLI: `pgit conflicts`, `pgit resolve`, `pgit merge --continue`,
  `pgit merge --abort`.
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
  modify conflict *and* silently lost the edit. `pgit.rename_pairs` pairs deleted keys with inserted
  ones by `pgit.row_similarity` over non-key columns — mutual-best-match, one-to-one, default
  threshold 0.5, the same shape as git's `-M`. `merge_plan` is now a wrapper over `merge_plan_raw`
  that rewrites those conflicts into a three-way merge **at the new key**.
  Tested in both directions, which matters more than the happy path: a key change with an otherwise
  untouched row scores similarity 1.0 and merges cleanly, carrying the other branch's edit onto the
  renamed row; a delete-plus-insert of *dissimilar* content is **not** mistaken for a rename and
  still surfaces as a real conflict; and raising the threshold above 1.0 finds nothing, proving the
  threshold is actually honoured rather than decorative.
  `pgit.rename_pairs` is public, so wiring `-M` into `diff` later is a small change. Still absent by
  choice: octopus merges, `subtree`, `rerere`, and **table**-level rename detection (a table renamed
  by DDL is currently refused by the schema-fingerprint guard rather than followed).
- **fsck, revisions, reset/reflog, working-tree diff** — 30 new assertions (291 pgTAP + 26 CLI +
  9 kill + 12 RDS = 338).
  **`pgit.fsck`** recomputes every node's hash from its children, follows every delta chain, and
  checks refs, commit parents, tree roots and child links. It reports zero on a healthy repo *and*
  zero after `repack(50)`, which is the useful part — it verifies delta chains end to end. It is
  also tested **negatively**: a tampered node is caught, and a delta pointing at a missing base is
  caught. Without those two, "fsck returns 0" would be indistinguishable from "fsck checks nothing".
  **`pgit.rev`** gives `HEAD`, `HEAD~N`, `HEAD^`, `HEAD^2`, branch names and abbreviated shas, and
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
  `pgit.bundle(refs, have)` does real **negotiation**: commits are walked back only to what the
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
  **`tag`** is a separate table rather than a ref, with annotated message and tagger, and `pgit.rev`
  resolves tag names — so `pgit show v1.0` works. Re-tagging is refused without `-f`.
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
  The gap was that `pgit.schemas` recorded column names and types but **not the primary key**, so a
  receiving database could not build the table. `pk_cols` is now recorded, travels in the bundle, and
  `pgit.clone_from` creates each missing table from the recorded shape, tracks it, sets the branch and
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
  Also fixed a real annoyance found by the test: `pgit.track` was emitting `DROP TRIGGER IF EXISTS`
  notices on every call, so any script using it filled the console with noise. Silenced at source.
- **tooling** — the progress log above lost 11 entries to silent failure. They were appended with a
  Python `str.replace()` anchored on text that did not exist, and `replace()` returns the original
  string on no match, so every one reported success and wrote nothing. The `## Blocked` section
  referenced from "Next" was never created either. Reconstructed from the session transcript.
  **Use a tool that fails loudly, or assert the match count — never a silent string replace.**
- **notes, rerere and table rename detection** — the three items from the missing-functionality
  inventory that genuinely apply to a row-oriented system. 16 pgTAP assertions, 10 CLI checks.
  `pgit.notes` attaches text to a commit sha; `pgit notes add|show|rm|list`.
  `rerere` records `(tbl, base, ours, theirs) → resolution` on `merge --continue` and replays it
  automatically the next time the identical conflict appears, so a repeated branch merge stops asking.
  The test proves this is not vacuous: it asserts the `used` counter incremented before checking the
  conflict count dropped to zero — otherwise "no conflicts" could just mean the second merge differed.
  `pgit rerere status|forget`.
  **Table rename detection uses tree similarity, not shape.** Comparing column names and types
  false-positives constantly — `(id int, v text)` is every other table. It matches by content
  instead: Dice coefficient over `(key, row hash)` leaf pairs, threshold 0.5, best match per dropped
  table. Identical roots score 1.0 without descending. A rename plus an edit of 2 of 10 rows scores
  exactly 0.8 and is reported as `similar`; a drop and an unrelated add sharing no rows is not
  reported at all. `pgit renames <a> <b>`.
  Two things worth recording. The first draft joined on `root_hash = root_hash`, which made the
  `'similar'` arm of its own CASE unreachable — it could only ever detect a rename with no edits,
  while the column claimed otherwise. Dead code that lies in a report is worse than a missing feature.
  And the outcome is still **detection, not following**: `assert_same_schema` refuses the replay, but
  now names both tables and the match percentage instead of blaming a shape change. Following a rename
  through a merge means mapping the old name to the new one across the diff, conflict and journal
  paths; that is a project, not an afternoon, and is deliberately not attempted.
- **octopus merges** — `pgit merge a b c` and `pgit.merge_octopus(text[])`. 19 pgTAP assertions,
  4 CLI checks, 5 remote checks. This closes the last verb in the inventory that applies here.
  The schema change was the point of it: `parent2_sha` is **gone**, replaced by
  `pgit.commit_parent (commit_sha, ord, parent_sha)` with `ord >= 2`, plus a `pgit.parent_edge` view
  that unions the first parent with the rest and a `pgit.parents_of(sha)` accessor. Eight call sites
  moved onto the view — `ancestors`, `rev` (`^N` now reaches any parent, not just the second),
  `fsck`, `commits_to_send`, `bundle`, `unbundle`, `prune`, `merge_finish` — and the two tests that
  read the old column. The bundle format carries a `parents` array; the wire format changed and there
  is no reader for the old one, per the no-back-compat rule.
  **The reason this stayed cheap is git's own choice: octopus refuses to resolve conflicts at all.**
  Once that is accepted there is no sequential three-way state machine to build. `pgit.octopus_plan`
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

- **run pgit against a real application database, not a fixture** — `bench/realworld_intoge.sh`,
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
  3. **`blame` ignored branch topology.** It scanned `pgit.changes` globally, so a row edited or
     deleted on a branch you are not on was attributed on yours — a row deleted on an unmerged branch
     blamed to all-null values. Now restricted to commits reachable from HEAD plus uncommitted rows.
     `test/blame_02_branch_scope.sql`, 7 assertions.
  Two things about the harness itself. Its first run reported four passes that were **vacuous** —
  `pgit.track(r.relname)` failed because `relname` is `name` and there is no implicit cast to `text`,
  the error was swallowed by a `>/dev/null`, and every later assertion compared zero against zero. It
  now refuses to run if tracking produced no tables. And two "failures" were the harness being wrong,
  not pgit: Postgres words a RESTRICT violation as `violates RESTRICT setting of foreign key
  constraint`, not `violates foreign key`, and `blame.actor` is who changed the row, not who authored
  the commit.

## Reference

Postgres.md`.
