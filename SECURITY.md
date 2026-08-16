# Security

## What pgit is, in security terms

pgit is SQL that runs inside your database, under the privileges of whoever calls it. It installs no
extension, opens no socket, and dials nothing. There is no network transport at all, so history
moves between databases only when you carry a bundle yourself.

Nothing in the `pgit` schema is reachable until it is granted:

```sql
SELECT pgit.grant_read('analytics');   -- log, diff, blame, show
SELECT pgit.grant_write('app');        -- and commit, branch, merge, revert
SELECT pgit.grant_admin('dba');        -- and track, gc, prune, reset, unbundle
```

## The parts that take foreign input

`unbundle`, `receive`, `fetch` and `clone_from` accept a bundle produced somewhere else. They are
**admin only** for that reason. A bundle carries column type names that end up in `CREATE TABLE`, so
types are validated through `to_regtype` before any DDL is interpolated. A bundle claiming a type of
`text); DROP TABLE users; --` is rejected rather than executed.

Two checks run on receipt, and both refuse rather than store. Every node is verified to hash to its
own content, so an altered node is rejected. And the bundle has to be **complete**: if any node
references a child the bundle does not carry, or any recorded tree has no root node in it, the whole
receipt is refused. Per-node hashing alone would not catch a bundle that was simply truncated, and a
truncated bundle produces a database that looks fine until you run `fsck`.

Treat a bundle like any other untrusted file: it decides what tables get created in the database you
unbundle it into.

## Running the development container

`docker-compose.yml` is for development. It binds Postgres to `127.0.0.1` with a throwaway password.
Do not expose it, and do not reuse that compose file for anything real.

## Reporting a vulnerability

Open a GitHub security advisory on this repository ("Security" → "Report a vulnerability"), which
keeps the report private until a fix exists. Please include the Postgres major version and, where
you can, a reproduction as SQL.

If you find a way to make pgit execute attacker-controlled SQL, write to a table the caller has no
rights to, or record a tree that disagrees with the data it claims to describe, that is the class of
bug worth reporting privately first.

## What is not a vulnerability

- Anything requiring the `pgit` admin grant. An admin can already drop your tables.
- Reading history you were granted read access to.
- `prune` losing `blame` attribution. That is documented in `docs/LIMITATIONS.md`: pruning buys
  storage with attribution, and `blame` marks the affected rows `exact = false` rather than guessing.
