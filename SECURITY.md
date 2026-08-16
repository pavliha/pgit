# Security

## What grove is, in security terms

grove is SQL that runs inside your database, under the privileges of whoever calls it. It installs no
extension, opens no socket, and dials nothing. There is no network transport at all, so history
moves between databases only when you carry a bundle yourself.

Nothing in the `grove` schema is reachable until it is granted:

```sql
SELECT grove.grant_read('analytics');   -- log, diff, blame, show
SELECT grove.grant_write('app');        -- and commit, branch, merge, revert
SELECT grove.grant_admin('dba');        -- and track, gc, prune, reset, unbundle
```

## The parts that take foreign input

`unbundle`, `receive`, `fetch` and `clone_from` accept a bundle produced somewhere else. They are
**admin only** for that reason. A bundle carries column type names that end up in `CREATE TABLE`, so
types are validated through `to_regtype` before any DDL is interpolated. A bundle claiming a type of
`text); DROP TABLE users; --` is rejected rather than executed.

Three checks run on receipt, and all of them refuse rather than store.

**Each node must hash to its content.** A node's hash covers the vector of its children's hashes, so
altering the structure is caught.

**The bundle must be complete.** If any node references a child the bundle does not carry, or a
recorded tree has no root node in it, the receipt is refused. Hashing alone would not catch a bundle
that was simply truncated, and a truncated one produces a database that looks healthy until you run
`fsck`.

**Every commit must hash to its own content.** A commit's sha covers its parent, author, message,
timestamp and the roots of its trees. Nothing verified that on receipt, so a bundle could carry any
author and any message under a genuine sha. It is checked now, which also means a commit's tree
cannot be repointed at a different root.

**The recorded shape must match its own fingerprint.** `checkout` refuses when a table's live shape
differs from the shape it had in the target commit, and it decides that by comparing fingerprints.
The fingerprint is `hash(columns)`, so nothing stopped a bundle from carrying an honest column list
next to a fingerprint copied from the receiving database's table. That combination passed the shape
guard: 300 rows were restored into a four-column table, the extra column was blanked on every row,
HEAD claimed the commit, and `fsck` reported nothing. `unbundle` now recomputes each fingerprint from
the columns stored beside it.

**Every row must be filed under its own key.** A node's hash covers the row hashes ordered by key, not
the keys themselves, so a key could be changed without changing any hash as long as the order held.
The row still carried correct data and every check passed, but the tree's index pointed at it under a
name that was not its primary key: `blame` returned nothing for that row, and the *next* commit built
a tree that no longer matched the table, with `fsck` reporting clean throughout. The key is now
re-derived from the row image on the way in, and by `fsck` for data at rest.

**The rows must hash to the tree.** This is the subtle one. A node's hash covers the *row hashes*,
not the cached row *images* beside them, so an attacker who edits an image and leaves its hash alone
produces a bundle where every node still hashes correctly and every structural check passes.
`unbundle` therefore recomputes each row's hash from the image the bundle carries, using the column
shape that bundle records for that commit, and refuses if any row does not match. Because every
entry point runs through `unbundle`, this covers `clone_from`, `fetch` and `receive` alike, and it
refuses before a single node is stored.

`clone_from` additionally rebuilds each materialised table and compares it to the root the bundle
claims. That is no longer the check that catches a tampered image; it is there to catch the
materialisation itself going wrong.

`grove.fsck()` asks the same three questions of data already at rest, since a repository can be
corrupted by something other than a bundle: it recomputes every commit sha, re-derives every schema
fingerprint from its columns, and re-hashes every stored row image. A repository poisoned by direct
SQL, or by a bundle accepted before these checks existed, reports the damage rather than reporting
clean.

**Nothing may arrive that the history does not need.** A bundle carries exactly the nodes reachable
from the trees it sends, so anything else is padding. It used to be stored anyway, which let a
sender grow the receiver's node store without limit with data nothing could ever read. Unreachable
nodes are refused now. This check runs after the others, so a bundle that is broken in a more
specific way is still reported that way.

Treat a bundle like any other untrusted file: it decides what tables get created in the database you
unbundle it into.

## Access levels

`grant_read`, `grant_write` and `grant_admin` decide what a role may call from two lists,
`grove.write_verbs()` and `grove.admin_only_verbs()`. Both are written by hand, and both had drifted:
`resolve_conflict` was missing beside `resolve_all`, `fetch` beside `receive`, and `grant_level`
beside the three wrappers that call it. A test now derives the set of functions that write from
`pg_proc` and fails if any of them is absent from both lists, so the lists cannot quietly fall behind
the code again.

The blanket `REVOKE ... FROM PUBLIC` used to run before the last ten functions in the file were
created, so those kept PostgreSQL's default public execute grant. A read role could call
`grant_level` and `log_rotate`, both admin-only. It ran out of road at the table grants, which are the
real boundary and were never wrong, but the intent of the lists was defeated for exactly those
functions. The revoke runs after every definition now.

## Running the development container

`docker-compose.yml` is for development. It binds Postgres to `127.0.0.1` with a throwaway password.
Do not expose it, and do not reuse that compose file for anything real.

## Reporting a vulnerability

Open a GitHub security advisory on this repository ("Security" → "Report a vulnerability"), which
keeps the report private until a fix exists. Please include the Postgres major version and, where
you can, a reproduction as SQL.

If you find a way to make grove execute attacker-controlled SQL, write to a table the caller has no
rights to, or record a tree that disagrees with the data it claims to describe, that is the class of
bug worth reporting privately first.

## What is not a vulnerability

- Anything requiring the `grove` admin grant. An admin can already drop your tables.
- Reading history you were granted read access to.
- `prune` losing `blame` attribution. That is documented in `docs/LIMITATIONS.md`: pruning buys
  storage with attribution, and `blame` marks the affected rows `exact = false` rather than guessing.
