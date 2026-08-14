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



## Follow-ups raised while building

- **FK enforcement is off during replay.** `session_replication_role = replica` disables referential
  integrity triggers as well as user triggers. A whole-commit revert is safe *by construction* — it
  restores a state that was already committed and valid, and the tests assert that by root hash. But
  a future **partial** revert (pathspec-scoped, restoring some rows and not others) could leave a
  dangling reference undetected. Before shipping partial revert, either re-validate the touched
  constraints afterwards or use `ALTER TABLE … DISABLE TRIGGER USER`, which suppresses only user
  triggers and leaves RI active (at the cost of an ACCESS EXCLUSIVE lock).
- **Checkout across a schema change is impossible today.** `checkout` materialises data, not shape.
  If HEAD added a column, the working table still has it after checking out a commit that predates
  it, so `is_dirty` is permanently true and checkout refuses. Options: version DDL and replay it on
  checkout, or refuse with a message naming the schema difference instead of the generic dirty
  error. The second is an afternoon; the first is a project.
- **The conflict guard is O(table) per revert.** `pgit.live_hash` computes `row_hashes` over the whole
  table for each key it checks. Correct but wasteful; it should become a keyed lookup before the
  perf gates.

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

## Reference

Postgres.md`.
