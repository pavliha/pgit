<h1 align="center">pgit</h1>

<p align="center">
  <strong>git for your data — branch, diff, merge and blame your rows.</strong><br>
  In stock PostgreSQL. No forked engine, no C extension, no managed service.
</p>

<p align="center">
  <a href="#run-the-tests"><img alt="tests" src="https://img.shields.io/badge/tests-679%20green-brightgreen"></a>
  <a href=".github/workflows/ci.yml"><img alt="postgres" src="https://img.shields.io/badge/postgres-16%20%7C%2017%20%7C%2018-blue"></a>
  <a href="#why-this-exists"><img alt="dependencies" src="https://img.shields.io/badge/extensions%20required-none-success"></a>
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-black"></a>
  <a href="#status"><img alt="status" src="https://img.shields.io/badge/status-pre--alpha-orange"></a>
</p>

---

```sql
SELECT pgit.track('products');
SELECT pgit.commit('the catalogue as it stands');

SELECT pgit.branch('black-friday');           -- branch your data
SELECT pgit.checkout('black-friday');
UPDATE products SET price = price * 0.7;      -- 40,000 rows, one statement
SELECT pgit.commit('30% off everything');

SELECT pgit.checkout('main');                 -- prices are back. all of them.
SELECT pgit.merge('black-friday');            -- ship it, column by column
```

That is a real branch of real rows in a real table. Between those calls your table is still a
**normal Postgres table** — indexed, constrained, transactional, queryable by everything you already
have. Nothing is exported, nothing is materialised, nothing leaves the database.

## The one number that matters

Diffing 10 changed rows **10,000 commits apart takes 163 ms** — the same as one commit apart.

That is the property the entire design exists for. `diff A B` costs *the size of the difference*,
not the history between the two commits, and not the size of the table. Everything else here is in
service of that.

## Yes, it beats git at git's own job — above a certain size

Same 12.7M-row IMDb dataset, committing a 100-row change:

| | git | pgit | |
| --- | ---: | ---: | --- |
| commit 100 changed rows, 12.7M-row dataset | 12,062 ms | **527 ms** | **22.9× faster** |
| commit 5,300 changed rows, 28 MB slice | **492 ms** | 1,801 ms | git 3.7× faster |

git's commit is O(file) — it re-hashes and re-compresses everything however little changed. pgit's
is O(changed). Below roughly 50 MB git wins on constants; above it pgit wins on complexity. The
crossover is lower than people expect, which is the whole point — and `PERF.md` has both directions,
because quoting only the best case would be quoting the best case.

git is also doing a different job: its result is a file you have to materialise. pgit's result is
still a database.

## Runs where your data already lives

Every verb is exercised as a plain `LOGIN` role with **no superuser rights** — strictly fewer
privileges than the RDS master user gets. So RDS, Neon and Supabase are covered by construction.
There is no C extension to install, no `pgcrypto` dependency, and no background worker.

Install is one file:

```bash
psql "$DATABASE_URL" -f sql/install.sql
```

## The full verb set

```
pgit status                     pgit log --oneline
pgit diff <a> <b> --stat -- products.price_amount
pgit blame products 42          pgit show HEAD~2      # HEAD, HEAD~N, HEAD^, branch, short sha
pgit branch feature && pgit checkout feature
pgit commit -m "..."            pgit reflog

pgit merge main                 # -X ours | -X theirs | -s ours
pgit merge a b c                # octopus: one commit, N parents, refuses on conflict like git
pgit conflicts                  # base/ours/theirs per conflict, queryable
pgit resolve products 42 theirs # or ours | base | delete
pgit merge --continue           # or --abort
pgit rerere status              # the same conflict resolves itself next time
pgit rebase main                pgit cherry-pick <sha>      pgit revert <sha>
pgit renames <a> <b>            # a renamed table, matched by content not by shape

pgit reset HEAD~1 --hard        # or --soft
pgit restore HEAD~3 -- products:42   # one row, or a whole table, without moving the branch
pgit stash / stash pop / stash list
pgit bisect start <good> <bad>  # then: bisect good | bisect bad
pgit tag v1.0 HEAD~2            pgit notes add HEAD -m "..."

pgit fsck                       # verify every hash, ref, chain and tree
pgit gc                         # pack node versions as deltas, and rotate the event log
pgit prune --before 2026-01-01  # truncate history, then collect unreachable nodes

pgit clone pack.json            # creates the tables, tracks them, materialises the data
pgit bundle main > pack.json    # or: --have have.json for an incremental pack
pgit fetch origin pack.json     # updates remotes/origin/* only, never your branches
pgit receive pack.json          # updates local branches, fast-forward enforced
```

Everything else git offers is **refused by name** — an unimplemented flag exits 129 saying which
flag, so nothing is ever silently ignored.

## It tells you what it did

Every write records one wide event, not a scatter of log lines:

```sql
SELECT verb, ok, actor, branch, duration_ms, detail FROM pgit.events ORDER BY id DESC;
```

```
verb     | ok | actor | branch | duration_ms | detail
commit   | t  | app   | main   |       6.314 | {"sha": "f59dd63", "journal_rows": 49, "tables": 1}
merge    | f  | app   | b1     |      31.002 | {"branch": "l", "conflicts": 1, "finished": false}
rebase   | t  | dba   | feat   |     104.220 | {"onto": "main", "was": "38d1a2c", "rewritten": true}
```

Every commit in the database has an event that created it — the test suite enforces that, so a new
verb cannot quietly bypass the audit log. `SELECT * FROM pgit.metrics()` gives the same database as
numbers to scrape, including commit latency percentiles.

## What it costs

Stated up front, because you will find them anyway:

- **Journalling costs about 10× the write it records.** A 10,000-row `UPDATE` goes from 26–30 ms to
  146–183 ms. This is the honest headline cost.
- **History costs storage** — 4.5× the table after 10,000 commits, **until `pgit gc`**, which takes
  it to 1.8× at the default depth and 1.2× at `--depth 50`.
- **Pruning buys storage with attribution.** `blame` marks what it can no longer prove
  `exact = false` rather than guessing at an author.
- **One database holds one branch at a time**, exactly like git's working tree.
- **Nothing outside the database branches.** Reverting a row does not un-send an email.

[`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) is the full list, and it is worth reading before
`PERF.md`.

## Why this exists

Everything shipping today makes one of two trades:

| | Trade |
| --- | --- |
| DoltgreSQL | leaves Postgres — own engine, no extensions, ~5.2× slower, no rebase or cherry-pick |
| pgGit | stays on Postgres, but versions **schema only** |
| postgresql-tableversion | rows and diffs, no branching |
| pg_branch, Neon, Lakebase | branch whole clusters, no row-level history |
| lakeFS, Nessie | full git model, but for data lakes, not OLTP |

**Row-level, full verb set, stock Postgres, OLTP is empty.** That is what this is.

## The bet

Four things Postgres already has, that a from-scratch git-for-data engine must build:

1. **`txid_current()`** groups a commit for free — one transaction is one changeset.
2. **Deferred constraints validate a merge.** Apply inside a transaction with constraints deferred,
   then set them immediate. Every FK, unique and check is verified by Postgres; a merge that would
   dangle a reference aborts on its own.
3. **`session_replication_role = replica`** disables user triggers, so replay during rebase or
   cherry-pick neither double-fires side effects nor records itself as new history.
4. **`sha256`, `normalize`, `trim_scale`** in core — canonicalisation with no dependencies.

## Design

Two layers, because the write path and the read path want opposite things:

| | `changes` journal | `nodes` tree |
| --- | --- | --- |
| written by | row trigger, per statement | commit, in bulk |
| serves | revert, rebase, cherry-pick, blame | diff, merge, checkout |
| canonical | no | **yes** |

The tree is a merkle forest with **content-defined chunk boundaries** — a key starts a new chunk
when `hash(key) mod target = 0`, a property of the key alone. That makes the tree
history-independent: the same content always produces the same root hash, whatever order it arrived
in. Which is what buys the 163 ms at the top of this page.

## Status

**Pre-alpha. The whole verb set works and is measured.**

**679 checks green** from an empty database in about 90 seconds — pgTAP, CLI, crash-safety,
non-superuser portability, remote and clone, randomised fuzzing, and 19 against a real 63-table
application schema. CI runs Postgres **16, 17 and 18** and requires **bit-identical root hashes**
across all three.

It has not run in production anywhere. The bugs found so far, how each was caught, and the several
cases where a green test suite failed to catch one, are all in [`BUILD_PLAN.md`](BUILD_PLAN.md).

## Run the tests

```bash
make up            # postgres 18 + pgTAP on port 5460, isolated
make test          # every suite, one total — about 90 seconds
make test-fast     # the pgTAP assertions alone
make bench         # the numbers in PERF.md

DUMP=/path/to/app.dump make test   # also run the real application schema suite
```

Each run builds its own database and installs `sql/install.sql` into it, so every run also proves
the installer from scratch — a forward reference or a duplicate definition cannot hide behind an
incremental install. CI runs the same script on the same image.

## Documentation

| | |
| --- | --- |
| [docs/USAGE.md](docs/USAGE.md) | install, track a table, commit, branch, merge, resolve conflicts, move history between databases |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | running it: health, events, metrics, backups, who can do what |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | canonical row form, content-defined chunking, the packed node format, and the invariants each test defends |
| [docs/LIMITATIONS.md](docs/LIMITATIONS.md) | what it costs, what it refuses, and what it will never do |
| [PERF.md](PERF.md) | every measurement, including the nine hypotheses that measured worse and were reverted |
| [CONTRIBUTING.md](CONTRIBUTING.md) | the rules that are actually enforced |

## Naming

`pgit` collides with two unrelated projects (`ImGajeed76/pgit`, `evoludigit/pgGit`). Renaming is
cheap while the repo is this small; it has not been decided.

## License

MIT.
