# Contributing

## Running it

```bash
make up        # postgres 16, 17 or 18 with pgtap, on port 5460
make install   # load sql/install.sql
make test      # every suite
```

`PG=16 make up` picks a major. CI runs 16, 17 and 18 and requires bit identical trees across all
three, so a change that depends on a newer built-in will fail there even when it passes for you.

## The rules that are actually enforced

**`sql/install.sql` is one file, and it is idempotent.** Each function appears exactly once, in
dependency order, with any `DROP FUNCTION IF EXISTS` immediately above its `CREATE`. Never append a
redefinition of something defined earlier. Edit it in place. A `LANGUAGE sql` function validates its
body at creation time, so a forward reference fails on a fresh database while working fine on yours.
Prove it from scratch before you claim it works:

```bash
make down && make up && make install && make test
```

**No comments in SQL or shell.** Test descriptions carry the meaning. If a function needs a comment
to be understood, the names are wrong.

**A fix ships with a test that fails without it.** Reintroduce the bug, watch the new test go red,
put the fix back. A test that passes both ways guards nothing, and this repo has shipped a few of
those before the rule existed.

**Performance claims need medians of at least five runs.** Single runs lie here. A change that read
as a 6% win over one run measured 11% slower over three. `./bench/gate.sh` does the medians and fails
on a ceiling breach. Machine drift is real: A/B the two versions back to back rather than comparing
against a number from an hour ago.

## Where things are

| path | what |
| --- | --- |
| `sql/install.sql` | the whole implementation |
| `bin/pgit` | the CLI, a thin shell over the SQL |
| `test/*.sql` | pgTAP, run by `test/run.sh` |
| `test/*_test.sh` | suites that need more than one session or database |
| `test/fuzz/` | randomised schemas and operations, replayable by seed |
| `bench/` | performance and storage, `gate.sh` is the one CI runs |
| `docs/ARCHITECTURE.md` | how the two layers fit together |
| `docs/LIMITATIONS.md` | what it deliberately does not do |

## Tests

Every write verb must leave an event in `pgit.events`; `test/obs_02_every_commit_audited.sql`
enforces that every commit in the database has an event that created it, so a new verb cannot
quietly bypass the audit log.

The fuzzer is worth understanding before you trust a green run. Its tables use a small
`chunk_target` so the trees are deep enough to exercise the incremental write path. At the default
of 64 a small table produces a level 1 root, which short circuits to a full rebuild and tests the
wrong code. If you change the fuzz fixture, check `pgit.nodes` still reaches level 2 or more.

## Reporting a bug

A seed and an operation count beat a description:

```
FUZZ_SEED=0.209411 FUZZ_ROUNDS=1 FUZZ_OPS=60 ./test/fuzz_test.sh
```

For anything about correctness of history, the reproduction that matters is the invariant:

```sql
SELECT t.tbl FROM pgit.trees t
WHERE t.commit_sha = pgit.resolve(pgit.head())
  AND pgit.write_tree(t.tbl::regclass) IS DISTINCT FROM t.root_hash;
```

No rows means every recorded tree still rebuilds from the live table. Rows mean a real bug.
