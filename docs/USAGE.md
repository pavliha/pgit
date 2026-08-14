# Using pgit

pgit puts your tables under version control in place. The tables stay exactly where they are —
queryable, indexed, constrained, writable by your application — and pgit records their history
alongside.

## Install

`sql/install.sql` is one idempotent script. Run it against the database you want to version:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f sql/install.sql
```

It creates a `pgit` schema and nothing else. It needs no extension, no superuser and no server
restart, which is why it runs on RDS, Neon and Supabase. Re-running it is safe and is how you
upgrade.

The CLI is `bin/pgit`, a shell wrapper over `psql`. Point it at the same database:

```bash
export PGIT_DSN="$DATABASE_URL"
```

Everything the CLI does is a SQL function call, so you can drive all of it from your application
without the CLI at all.

## Track a table

```sql
SELECT pgit.track('products');
```

The table needs a primary key — that is what identifies a row across branches. Tracking installs
three statement triggers and one index on the canonical key.

Tracking does not read the table. Nothing is recorded until you commit.

## The first commit

```bash
pgit commit -m "baseline"
```

A commit snapshots **every tracked table** as of now. The first one builds the whole tree, so it is
proportional to your data; later ones are proportional to what changed, and tables you did not touch
cost nothing.

```bash
pgit status                 # branch, and whether the tables differ from HEAD
pgit log --oneline
pgit show HEAD
```

## Day to day

Write to your tables normally — through your application, a migration, `psql`, anything. pgit's
triggers record each change as it happens. When you want a point you can return to, commit:

```sql
UPDATE products SET price_amount = price_amount * 110 / 100 WHERE category_id = 5;
```
```bash
pgit commit -m "raise category 5 by 10%"
```

A commit is a transaction boundary in the ordinary sense: everything committed to the database since
the last `pgit commit` becomes one changeset.

### Seeing what changed

```bash
pgit diff                              # working tables against HEAD
pgit diff HEAD~3 HEAD                  # between two commits
pgit diff HEAD~3 HEAD --stat
pgit diff HEAD~3 HEAD -- products      # one table
pgit diff HEAD~3 HEAD -- products.price_amount   # one column
pgit diff HEAD~3 HEAD -- products:42   # one row
```

Diff cost tracks the size of the difference, not the distance between the commits. Ten changed rows
ten thousand commits apart costs the same as ten changed rows one commit apart.

### Who changed this row

```bash
pgit blame products 42
```

Per column: the value, the commit that set it, and when. Blame follows the branch you are on — a
change made on a branch you have not merged is not attributed to you.

### Undoing

```bash
pgit revert <sha>              # a new commit that undoes that one
pgit restore HEAD~3 -- products:42    # one row back to an old value, branch unmoved
pgit reset HEAD~1 --hard       # move the branch and materialise it
```

`revert` refuses if the rows it would change have moved since, rather than silently clobbering.

## Branching

```bash
pgit branch pricing
pgit checkout pricing
```

**A branch is a checkout, not a copy.** One database holds one branch at a time, exactly like git's
working tree. Checking out materialises that branch's data into your tables. It refuses if you have
uncommitted changes.

This is the part that most needs thinking about before you adopt it: while you are on `pricing`, your
application sees `pricing`'s data. That is fine for a single-tenant workflow — a data migration you
want to review, a bulk edit you want to be able to abandon — and wrong for anything where two
branches must be readable at once.

```bash
pgit merge pricing             # -X ours | -X theirs | -s ours
pgit merge a b c               # octopus: one commit, N parents
```

Merges are three-way per column, so two branches that changed different columns of the same row
merge cleanly.

**Your constraints validate the merge.** pgit applies the merged state with constraints live and
deferred ones set immediate before committing, so a merge that would dangle a foreign key or break a
unique index aborts on its own. That is not a check pgit implements; it is Postgres refusing.

### Conflicts

```bash
pgit merge pricing
# 3 conflict(s); resolve with 'pgit resolve', then 'pgit merge --continue'

pgit conflicts                          # base / ours / theirs per row, queryable
pgit resolve products 42 theirs         # or ours | base | delete
pgit merge --continue                   # or --abort
```

Conflicts live in `pgit.conflicts`, so you can resolve them with SQL rather than one at a time:

```sql
SELECT pgit.resolve_conflict(merge_id, tbl, k, 'theirs')
FROM pgit.conflicts WHERE merge_id = 7 AND tbl = 'products';
```

`pgit rerere status` shows resolutions pgit has remembered; the same conflict resolves itself next
time it appears.

## Housekeeping

```bash
pgit fsck                      # verify every hash, ref, chain and tree
pgit gc                        # pack old node versions as deltas
pgit gc --depth 50             # more aggressive
pgit prune --before 2026-01-01 # truncate history, then collect what is unreachable
```

**Run `gc`.** History is stored as full node versions until you do, and packing removes most of it.
Any storage figure quoted without it is roughly three to four times the real one.

`prune` is the only thing here that destroys history. There is no default retention policy — that is
a decision pgit deliberately does not make for you.

## Moving history between databases

There is no server. History moves as a **bundle**: one self-contained JSON value.

```bash
pgit bundle main > pack.json           # everything reachable from main
pgit clone pack.json                   # into an empty database: creates the tables and fills them

pgit remote add origin /path/or/url
pgit have > have.json                  # what this database already holds
pgit bundle main --have have.json > incr.json   # only what it lacks
pgit fetch origin incr.json            # updates remotes/origin/* only
pgit receive incr.json                 # updates local branches, fast-forward enforced
pgit receive incr.json --force
```

Every node in a bundle is verified against its own hash on receipt; a tampered bundle is refused.

`clone` reproduces column names, types and the primary key — enough to hold the data and hash
identically. It does **not** reproduce foreign keys, defaults, checks or secondary indexes. Read it
as "clone the history", not "clone the schema".

## Everything else

```bash
pgit tag v1.0 HEAD~2
pgit notes add HEAD -m "reviewed by ops"
pgit stash / stash pop / stash list
pgit bisect start <good> <bad>   # then: bisect good | bisect bad
pgit cherry-pick <sha>
pgit rebase main
pgit reflog
pgit renames <a> <b>             # a renamed table, matched by content
```

Revisions work where you expect them: `HEAD`, `HEAD~3`, `HEAD^2`, a branch name, a tag, a short sha.

Anything git offers that pgit does not implement is **refused by name** — an unsupported flag exits
129 saying which flag, so nothing is ever silently ignored.

## Before you adopt it

Read [LIMITATIONS.md](LIMITATIONS.md). The short version: writes cost about 15 µs per changed row,
reads are unaffected, schema changes are not versioned, and one database holds one branch at a time.
