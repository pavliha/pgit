#!/usr/bin/env bash
set -uo pipefail

# Runs pgit against a real application database rather than a synthetic fixture.
# Point DUMP at a pg_dump custom-format snapshot; it is restored into its own
# database on the pgit cluster and never written back.
#
#   DUMP=/path/to/app.dump ./bench/realworld_intoge.sh

ADMIN="${PGIT_ADMIN_DSN:-postgresql://postgres:pgit@localhost:5460/postgres}"
DSN="${PGIT_REAL_DSN:-postgresql://postgres:pgit@localhost:5460/pgit_intoge}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
DUMP="${DUMP:-}"
N=0; FAILED=0

ok(){ N=$((N+1)); printf 'ok %d - %s\n' "$N" "$1"; }
nok(){ N=$((N+1)); FAILED=1; printf 'not ok %d - %s\n' "$N" "$1"; }
is(){ if [ "$2" = "$3" ]; then ok "$1"; else nok "$1 (want '$3', got '$2')"; fi; }
q(){ psql "$DSN" -X -q -At -c "$1" 2>&1; }
qs(){ psql "$DSN" -X -q -At -v ON_ERROR_STOP=1 -c "$1" 2>&1; }

if [ -n "$DUMP" ]; then
  [ -f "$DUMP" ] || { echo "dump not found: $DUMP" >&2; exit 66; }
  psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS pgit_intoge" -c "CREATE DATABASE pgit_intoge" >/dev/null 2>&1
  pg_restore --no-owner --no-privileges -d "$DSN" "$DUMP" >/dev/null 2>&1
fi

psql "$DSN" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1

echo "# tracking every table with a primary key"
qs "DO \$\$
    DECLARE r record;
    BEGIN
      FOR r IN
        SELECT c.relname::text AS t FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relkind = 'r'
          AND c.relname <> '__drizzle_migrations'
          AND EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'p')
        ORDER BY c.relname
      LOOP
        PERFORM pgit.track(r.t);
      END LOOP;
    END \$\$"

TRACKED=$(q "SELECT count(*) FROM pgit.tracked")
echo "# tracked $TRACKED tables"

# Without this guard every assertion below compares zero against zero and passes.
if ! [ "$TRACKED" -gt 10 ] 2>/dev/null; then
  echo "not ok - realworld: tracking produced $TRACKED tables, refusing to run vacuous assertions" >&2
  exit 1
fi

T0=$(python3 -c 'import time;print(time.time())')
qs "SELECT pgit.commit('baseline of the real database','realworld')" >/dev/null
T1=$(python3 -c 'import time;print(time.time())')
printf '# baseline commit over %s tables took %.1f s\n' "$TRACKED" "$(echo "$T1 - $T0" | bc -l)"

is "realworld: the baseline commit produced a tree for every tracked table" \
   "$(q "SELECT count(*) FROM pgit.trees WHERE commit_sha = pgit.resolve('main')")" "$TRACKED"

is "realworld: the working tree is clean straight after committing it" "$(q "SELECT pgit.is_dirty()")" "f"

is "realworld: fsck finds nothing wrong" "$(q "SELECT count(*) FROM pgit.fsck()")" "0"

is "realworld: a full rebuild of every table reproduces the recorded root hash" \
   "$(q "SELECT count(*) FROM pgit.tracked t
         JOIN pgit.trees r ON r.tbl = t.tbl::text AND r.commit_sha = pgit.resolve('main')
         WHERE pgit.write_tree(t.tbl) IS DISTINCT FROM r.root_hash")" "0"

echo "# a real pricing change on a branch"
qs "SELECT pgit.branch('pricing')" >/dev/null
qs "SELECT pgit.checkout('pricing')" >/dev/null
CHANGED=$(qs "WITH u AS (UPDATE products SET price_amount = (price_amount * 1.1)::int,
                            updated_at = now() WHERE is_active RETURNING 1) SELECT count(*) FROM u")
qs "SELECT pgit.commit('raise active prices by 10 percent','pricing bot')" >/dev/null
case "$CHANGED" in (*[!0-9]*|"") echo "not ok - reprice failed: $CHANGED" >&2; exit 1;; esac
echo "# repriced $CHANGED products"

is "realworld: the diff sees exactly the repriced rows" \
   "$(q "SELECT count(*) FROM pgit.diff(pgit.rev('pricing~1'), pgit.resolve('pricing'))")" "$CHANGED"

is "realworld: and attributes every one of them to the products table" \
   "$(q "SELECT count(DISTINCT tbl) FROM pgit.diff(pgit.rev('pricing~1'), pgit.resolve('pricing'))")" "1"

echo "# an unrelated translation change on main"
qs "SELECT pgit.checkout('main')" >/dev/null
TR=$(qs "WITH u AS (UPDATE product_locale SET long_description = COALESCE(long_description,'') || ' (reviewed)'
                    WHERE locale = 'ka' RETURNING 1) SELECT count(*) FROM u")
qs "SELECT pgit.commit('review the georgian copy','editor')" >/dev/null
case "$TR" in (*[!0-9]*|"") echo "not ok - translation update failed: $TR" >&2; exit 1;; esac
echo "# retranslated $TR rows"

MERGED=$(qs "SELECT pgit.merge('pricing')")
is "realworld: merging a pricing branch into a translation branch has no conflicts" "$MERGED" "0"

is "realworld: the merge kept both changes" \
   "$(q "SELECT count(*) FROM pgit.diff(pgit.rev('main~2'), pgit.resolve('main'))")" "$((CHANGED + TR))"

is "realworld: fsck is still clean after the merge" "$(q "SELECT count(*) FROM pgit.fsck()")" "0"
is "realworld: the merge left the working tree clean" "$(q "SELECT pgit.is_dirty()")" "f"

echo "# two branches editing the same product price"
PID=$(q "SELECT id FROM products WHERE is_active ORDER BY id LIMIT 1")
qs "SELECT pgit.branch('promo')" >/dev/null
qs "SELECT pgit.checkout('promo')" >/dev/null
qs "UPDATE products SET price_amount = 111 WHERE id = $PID" >/dev/null
qs "SELECT pgit.commit('promo price','marketing')" >/dev/null
qs "SELECT pgit.checkout('main')" >/dev/null
qs "UPDATE products SET price_amount = 222 WHERE id = $PID" >/dev/null
qs "SELECT pgit.commit('list price','finance')" >/dev/null

CONF=$(qs "SELECT pgit.merge('promo')")
is "realworld: the same product edited on both sides is one conflict" "$CONF" "1"

MID=$(q "SELECT max(id) FROM pgit.merges")
K=$(q "SELECT k FROM pgit.conflicts WHERE merge_id = $MID LIMIT 1")
qs "SELECT pgit.resolve_conflict($MID, 'products', '$K', 'theirs')" >/dev/null
qs "SELECT pgit.merge_finish($MID)" >/dev/null
is "realworld: resolving to theirs takes the promo price" "$(q "SELECT price_amount FROM products WHERE id = $PID")" "111"
is "realworld: fsck is clean after a resolved conflict" "$(q "SELECT count(*) FROM pgit.fsck()")" "0"

echo "# a merge that would dangle a real foreign key"
# products -> categories is ON DELETE RESTRICT in this schema, so it is the one
# that can actually be violated by combining two independently valid branches.
must(){ out=$(qs "$1"); case "$out" in *ERROR*) echo "setup failed: $out" >&2; exit 1;; esac; printf '%s' "$out"; }

CID=$(must "SELECT category_id FROM products WHERE category_id IS NOT NULL
            GROUP BY 1 ORDER BY count(*) DESC LIMIT 1")
case "$CID" in (*[!0-9]*|"") echo "no category to test with: $CID" >&2; exit 1;; esac

must "SELECT pgit.branch('cleanup')" >/dev/null
must "SELECT pgit.checkout('cleanup')" >/dev/null
GONE=$(must "WITH d AS (DELETE FROM products WHERE category_id = $CID RETURNING 1) SELECT count(*) FROM d")
must "DELETE FROM categories WHERE id = $CID" >/dev/null
must "SELECT pgit.commit('retire a category and its products','ops')" >/dev/null
echo "# cleanup branch removed $GONE products and category $CID"

must "SELECT pgit.checkout('main')" >/dev/null
NEWSKU="pgit-realworld-probe"
must "INSERT INTO products (slug, sku, price_amount, price_currency, category_id, is_active, created_at, updated_at)
      VALUES ('$NEWSKU', '$NEWSKU', 1000, 'GEL', $CID, true, now(), now())" >/dev/null
must "SELECT pgit.commit('new product in that category','merch')" >/dev/null

is "realworld: the new product really is in the category the other branch deleted" \
   "$(q "SELECT count(*) FROM products WHERE sku = '$NEWSKU' AND category_id = $CID")" "1"

OUT=$(q "SELECT pgit.merge('cleanup')")
if printf '%s' "$OUT" | grep -qiE 'violates (foreign key|RESTRICT setting)'; then
  ok "realworld: Postgres refuses the merge that would dangle a real foreign key"
else
  nok "realworld: Postgres refuses the merge that would dangle a real foreign key (got '$OUT')"
fi

is "realworld: the refused merge rolled back, the category is still there" \
   "$(q "SELECT count(*) FROM categories WHERE id = $CID")" "1"
is "realworld: and the working tree still matches the commit before it" "$(q "SELECT pgit.is_dirty()")" "f"

echo "# blame on a real row"
is "realworld: blame reports the price the row actually holds now" \
   "$(q "SELECT value #>> '{}' FROM pgit.blame('products', '$PID') WHERE col = 'price_amount'")" \
   "$(q "SELECT price_amount::text FROM products WHERE id = $PID")"

is "realworld: and blames it to a commit on this branch, not the branch we refused to merge" \
   "$(q "SELECT count(*) FROM pgit.blame('products', '$PID') b
         WHERE b.col = 'price_amount'
           AND b.commit_sha IN (SELECT a FROM pgit.ancestors(pgit.resolve('main')))")" "1"

SIZE=$(q "SELECT pg_size_pretty(pg_total_relation_size('pgit.nodes'))")
TBL=$(q "SELECT pg_size_pretty(sum(pg_total_relation_size(relid))::bigint) FROM pg_stat_user_tables WHERE relname NOT LIKE 'pgit%'")
echo "# node store $SIZE against $TBL of application tables"

echo
[ $FAILED -eq 0 ] && echo "REALWORLD GREEN ($N checks)" || echo "REALWORLD RED"
exit $FAILED
