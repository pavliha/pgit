<h1 align="center">grove</h1>

<p align="center">
  <strong>git for your data. Branch, diff, merge and blame your rows.</strong><br>
  It runs inside stock PostgreSQL, with no forked engine and nothing to install but one SQL file.
</p>

<p align="center">
  <a href="#run-the-tests"><img alt="tests" src="https://img.shields.io/badge/tests-1085%20green-brightgreen"></a>
  <a href=".github/workflows/ci.yml"><img alt="postgres" src="https://img.shields.io/badge/postgres-16%20%7C%2017%20%7C%2018-blue"></a>
  <a href="#why-this-exists"><img alt="dependencies" src="https://img.shields.io/badge/extensions%20required-none-success"></a>
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-black"></a>
  <a href="#status"><img alt="status" src="https://img.shields.io/badge/status-pre--alpha-orange"></a>
</p>

---

```sql
SELECT grove.track('products');
SELECT grove.commit('the catalogue as it stands');

SELECT grove.branch('black-friday');           -- branch your data
SELECT grove.checkout('black-friday');
UPDATE products SET price = price * 0.7;      -- 40,000 rows, one statement
SELECT grove.commit('30% off everything');

SELECT grove.checkout('main');                 -- prices are back. all of them.
SELECT grove.merge('black-friday');            -- ship it, column by column
```

None of that is a metaphor. `products` stays an ordinary Postgres table the whole way through,
indexed and constrained and queryable by everything else you already run against it. No export step,
and no copy of your data living somewhere outside the database.

## Diff cost tracks the diff, not the history

Diffing 10 changed rows 10,000 commits apart takes **163 ms**. One commit apart takes the same.

That is what the whole design is for. `diff A B` costs the size of the difference between A and B,
not the number of commits between them, and not the size of the table.

## Measured against git

Run it yourself with `make bench-git`. Same generated data, same change sets, medians of three,
100 changed rows per commit. git 2.55.0, Postgres 18.

| rows | as a TSV | first commit | commit 100 rows | diff one commit | store after gc |
| ---: | ---: | --- | --- | --- | --- |
| 50,000 | 1.7 MB | git **81 ms** / grove 388 ms | git **75 ms** / grove 114 ms | git **33 ms** / grove 118 ms | git **488 kB** / grove 4.2 MB |
| 500,000 | 18 MB | git **139 ms** / grove 2,603 ms | git 235 ms / grove **211 ms** | git **126 ms** / grove 146 ms | git **3.6 MB** / grove 33.6 MB |
| 2,000,000 | 74 MB | git **373 ms** / grove 11,147 ms | git 931 ms / grove **436 ms** | git 519 ms / grove **169 ms** | git **14.6 MB** / grove 135 MB |

Read the diff column downwards. grove goes 118, 146, 169 ms across 40x more data. git goes 33, 126,
519 ms, which is linear in the file, because git diffs two whole blobs and grove walks only the part
of the tree that changed.

Commit tells the same story more slowly. git's commit is O(file): it re-hashes and re-compresses
everything however little changed. grove's is O(changed). For a 100-row change they cross at about
18 MB, and by 74 MB grove is 2.1x ahead. Change 5,000 rows instead and the crossover moves up, so it
depends on how much you touched and not on size alone.

Two things git wins outright. **The first commit, always**, by 4.7x at 50k rows and 29.8x at 2M,
because building a tree from nothing hashes every row individually where git makes one pass over a
byte stream. And **storage, by about 9x at every size**, which is the flattest number in the table
and does not improve with scale.

git is also doing a different job. What it hands back is a file you have to load before you can ask
it anything. What grove hands back is still a database.

## Runs where your data already lives

Every verb is exercised as a plain `LOGIN` role with no superuser rights, which is strictly fewer
privileges than the RDS master user gets. So RDS, Neon and Supabase work by construction. There is no
C extension to install, no `pgcrypto` dependency, and no background worker.

Install is one file:

```bash
psql "$DATABASE_URL" -f sql/install.sql
```

## The full verb set

```
grove status                     grove log --oneline
grove diff <a> <b> --stat -- products.price_amount
grove blame products 42          grove show HEAD~2      # HEAD, HEAD~N, HEAD^, branch, short sha
grove branch feature && grove checkout feature
grove commit -m "..."            grove reflog

grove merge main                 # -X ours | -X theirs | -s ours
grove merge a b c                # octopus: one commit, N parents, refuses on conflict like git
grove conflicts                  # base/ours/theirs per conflict, queryable
grove resolve products 42 theirs # or ours | base | delete
grove merge --continue           # or --abort
grove rerere status              # the same conflict resolves itself next time
grove rebase main                grove cherry-pick <sha>      grove revert <sha>
grove renames <a> <b>            # a renamed table, matched by content not by shape

grove reset HEAD~1 --hard        # or --soft
grove restore HEAD~3 -- products:42   # one row, or a whole table, without moving the branch
grove stash / stash pop / stash list
grove bisect start <good> <bad>  # then: bisect good | bisect bad
grove tag v1.0 HEAD~2            grove notes add HEAD -m "..."

grove fsck                       # re-derive every hash, sha, shape and row image
grove gc                         # pack node versions as deltas, and rotate the event log
grove prune --before 2026-01-01  # truncate history, then collect unreachable nodes

grove clone pack.json            # creates the tables, tracks them, materialises the data
grove bundle main > pack.json    # or: --have have.json for an incremental pack
grove fetch origin pack.json     # updates remotes/origin/* only, never your branches
grove receive pack.json          # updates local branches, fast-forward enforced
```

Anything git offers that grove does not implement is refused by name. An unimplemented flag exits 129
and tells you which flag, so nothing gets silently ignored.

## It tells you what it did

Every write records one wide event rather than a scatter of log lines:

```sql
SELECT verb, ok, actor, branch, duration_ms, detail FROM grove.events ORDER BY id DESC;
```

```
verb     | ok | actor | branch | duration_ms | detail
commit   | t  | app   | main   |       6.314 | {"sha": "f59dd63", "journal_rows": 49, "tables": 1}
merge    | f  | app   | b1     |      31.002 | {"branch": "l", "conflicts": 1, "finished": false}
rebase   | t  | dba   | feat   |     104.220 | {"onto": "main", "was": "38d1a2c", "rewritten": true}
```

Every commit in the database has an event that created it, and a test enforces that, so a new verb
cannot quietly bypass the audit log. `SELECT * FROM grove.metrics()` gives you the same database as
numbers to scrape, including commit latency percentiles.

## What it costs

Up front, because you will find them anyway:

- Journalling costs about **10x the write it records**. A 10,000-row `UPDATE` goes from 26-30 ms to
  146-183 ms. That is the honest headline cost.
- History costs storage. About 4.5x the table after 10,000 commits, until `grove gc` takes it to 1.8x
  at the default depth and 1.2x at `--depth 50`.
- Pruning buys that storage with attribution. `blame` marks whatever it can no longer prove as
  `exact = false` instead of guessing at an author.
- One database holds one branch at a time, the same way git's working tree does.
- Nothing outside the database branches. Reverting a row does not un-send an email.

[`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) has the full list, and it is worth reading before
`PERF.md`.

## Why this exists

Everything shipping today makes one of two trades:

| | Trade |
| --- | --- |
| DoltgreSQL | leaves Postgres. Own engine, no extensions, ~5.2x slower, no rebase or cherry-pick |
| pgGit | stays on Postgres, but versions schema only |
| postgresql-tableversion | rows and diffs, no branching |
| pg_branch, Neon, Lakebase | branch whole clusters, no row-level history |
| lakeFS, Nessie | full git model, but for data lakes rather than OLTP |

Row-level, full verb set, stock Postgres, OLTP is empty. That is what this is.

## The bet

Four things Postgres already has, that a from-scratch git-for-data engine has to build:

1. `txid_current()` groups a commit for free. One transaction is one changeset.
2. Deferred constraints validate a merge. Apply inside a transaction with constraints deferred, then
   set them immediate. Postgres verifies every FK, unique and check itself, and a merge that would
   dangle a reference aborts on its own.
3. `session_replication_role = replica` disables user triggers, so replay during rebase or
   cherry-pick neither double-fires side effects nor records itself as new history.
4. `sha256`, `normalize` and `trim_scale` are in core, so canonicalisation needs no dependencies.

## Design

Two layers, because the write path and the read path want opposite things:

| | `changes` journal | `nodes` tree |
| --- | --- | --- |
| written by | row trigger, per statement | commit, in bulk |
| serves | revert, rebase, cherry-pick, blame | diff, merge, checkout |
| canonical | no | yes |

The tree is a merkle forest with content-defined chunk boundaries. A key starts a new chunk when
`hash(key) mod target = 0`, which is a property of the key alone. That makes the tree
history-independent: the same content always produces the same root hash, whatever order it arrived
in. Which is what buys the 163 ms at the top of this page.

## Status

Pre-alpha. The whole verb set works and is measured.

**1085 checks green** from an empty database in about sixteen minutes, two thirds of that the
randomised fuzzing, covering pgTAP, the CLI, crash-safety, non-superuser portability, remote and
clone. CI runs Postgres 16, 17 and 18, requires bit-identical root hashes across all three, and
checks that number on every push. Point `DUMP` at a `pg_dump` of your own database and 19 more run
against a real application schema; those are not counted above, because CI has no such fixture and a
number nothing verifies is not worth publishing.

It has not run in production anywhere. The bugs found so far, how each one was caught, and the
several cases where a green test suite failed to catch one, are in [`BUILD_PLAN.md`](BUILD_PLAN.md).

## Run the tests

```bash
make up            # postgres 18 + pgTAP on port 5460, isolated
make test          # every suite, one total, about 90 seconds
make test-fast     # the pgTAP assertions alone
make bench         # the numbers in PERF.md

DUMP=/path/to/app.dump make test   # also run the real application schema suite
```

Each run builds its own database and installs `sql/install.sql` into it, so every run also proves the
installer from scratch. A forward reference or a duplicate definition cannot hide behind an
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

Named for what it builds: a merkle **forest**, one tree per tracked table, which is what makes a
diff cost the size of the difference rather than the length of the history.

It was called `pgit` until it had users to confuse, which is to say never. That name collided with
two unrelated projects (`ImGajeed76/pgit`, `evoludigit/pgGit`) and said nothing about the design.

## License

MIT.
