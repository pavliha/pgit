# pgit

Git semantics over data in **stock PostgreSQL**, as a plain SQL plugin. No forked engine, no C
extension, no managed service. `commit`, `log`, `diff`, `blame`, `revert`, `branch`, `merge`,
`rebase`, `cherry-pick` — with git's flag names and git's diff performance.

**Status: pre-alpha, but the whole verb set works and is measured.** 406 checks green from an empty
database (327 pgTAP + 36 CLI + 9 crash-safety + 12 non-superuser portability + 22 remote and clone).

**Runs on managed Postgres.** Every verb is exercised as a plain `LOGIN` role with no superuser
rights — strictly fewer privileges than the RDS master user gets — so RDS, Neon and Supabase are
covered by construction. There is no C extension to install and no `pgcrypto` dependency. On a 1M-row table a commit touching 10 rows takes
**25 ms**, and diffing 10 changed rows **10,000 commits apart** takes **163 ms** — the same as one
commit apart.

Two things to know before using it, both in `PERF.md`: journalling costs about **10× the write it
records**, and 10,000 commits grew the node store to **5× the size of the table** — history costs
storage, and it grows with commit count rather than data size. Neither is hidden; both are open
decisions in `BUILD_PLAN.md`.

```
pgit status
pgit log --oneline
pgit diff <a> <b> --stat -- products.price_amount
pgit blame products 42
pgit show HEAD~2                # revisions: HEAD, HEAD~N, HEAD^, branch, short sha
pgit branch feature && pgit checkout feature
pgit commit -m "..."
pgit merge main                 # -X ours | -X theirs | -s ours
pgit conflicts                  # base/ours/theirs per conflict, queryable
pgit resolve products 42 theirs # or ours | base | delete
pgit merge --continue           # or --abort
pgit rerere status              # the same conflict resolves itself next time
pgit renames <a> <b>            # a renamed table, matched by content not by shape
pgit rebase main
pgit diff                       # working tree against HEAD
pgit reset HEAD~1 --hard        # or --soft
pgit reflog
pgit fsck                       # verify every hash, ref, chain and tree
pgit gc                         # pack node versions as deltas

pgit clone pack.json            # creates the tables, tracks them, materialises the data
pgit remote add origin <url>    # history moves between databases as bundles
pgit bundle main > pack.json    # or: --have have.json for an incremental pack
pgit fetch origin pack.json     # updates remotes/origin/* only, never your branches
pgit receive pack.json          # updates local branches, fast-forward enforced

pgit tag v1.0 HEAD~2            # tags resolve as revisions
pgit notes add HEAD -m "..."    # or: notes show | notes rm | notes list
pgit restore HEAD~3 -- products:42   # one row, or a whole table, without moving the branch
pgit stash / stash pop / stash list
pgit bisect start <good> <bad>  # then: bisect good | bisect bad
pgit prune --before 2026-01-01  # truncate history, then collect unreachable nodes
pgit cherry-pick <sha>
pgit revert <sha>
```

Everything else git offers is refused by name — an unimplemented flag exits 129 saying which flag,
so nothing is ever silently ignored.

## Why this exists

Everything shipping today makes one of two trades:

| | Trade |
| --- | --- |
| DoltgreSQL | leaves Postgres — own engine, no extensions, ~5.2× slower, no rebase or cherry-pick |
| pgGit | stays on Postgres, but versions **schema only** |
| postgresql-tableversion | rows and diffs, no branching |
| pg_branch, Neon, Lakebase | branch whole clusters, no row-level history |
| lakeFS, Nessie | full git model, but for data lakes, not OLTP |

Row-level, full verb set, stock Postgres, OLTP is empty. That is what this is.

## The bet

Four things Postgres already has, that a from-scratch git-for-data engine must build:

1. **`txid_current()`** groups a commit for free — one transaction is one changeset.
2. **Deferred constraints validate a merge.** Apply inside a transaction with constraints
   deferred, then set them immediate. Every FK, unique and check is verified by Postgres; a merge
   that would dangle a reference aborts on its own.
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
when `hash(key) mod target = 0`, a property of the key alone. That makes the tree history-
independent: the same content always produces the same root hash, whatever order it arrived in.
Which is what buys git's defining property — **`diff A B` costs O(size of the difference)**, not
O(history between them) and not O(table size).

## Run the tests

```bash
make up        # postgres 18 + pgTAP on port 5460, isolated
make test      # every suite: pgTAP, CLI, crash-safety, non-superuser, remote
make bench     # the numbers in PERF.md
```

## Scope, permanently

Search indexes, object storage, payment providers and outbound notifications do not branch and
never will. `pgit` versions rows in one database. Anything else your application does in response
to a write is your application's problem — reverting a row does not un-send an email.

## Naming

`pgit` collides with two unrelated projects (`ImGajeed76/pgit`, `evoludigit/pgGit`). Renaming is
cheap while the repo is this small; it has not been decided.

## License

MIT.
