#!/usr/bin/env bash
set -uo pipefail

ADMIN="${PGIT_ADMIN_DSN:-postgresql://postgres:pgit@${PGIT_HOST:-localhost:5460}/postgres}"
DB="${VSDB:-pgit_vsgit}"
DSN="postgresql://postgres:pgit@${PGIT_HOST:-localhost:5460}/$DB"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIZES="${SIZES:-50000 500000 2000000}"
CHANGED="${CHANGED:-100}"
RUNS="${RUNS:-3}"

command -v git >/dev/null || { echo "git not on PATH" >&2; exit 66; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

now_ms(){ python3 -c 'import time;print(int(time.time()*1000))'; }
median(){ printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }
q(){ psql "$DSN" -X -q -At -v ON_ERROR_STOP=1 -c "$1"; }

echo "# pgit against git, same data, same change sets"
echo "# $(git --version), postgres $(psql "$ADMIN" -X -At -c 'SHOW server_version' | cut -d. -f1), medians of $RUNS"
echo
printf '%-10s %-22s %12s %12s %s\n' rows operation git pgit winner

for ROWS in $SIZES; do
  psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" -c "CREATE DATABASE $DB" >/dev/null 2>&1
  psql "$DSN" -X -q -v ON_ERROR_STOP=1 -f "$DIR/sql/install.sql" >/dev/null 2>&1

  psql "$DSN" -X -q -v ON_ERROR_STOP=1 \
    -c "CREATE TABLE r (id bigint PRIMARY KEY, title text NOT NULL, votes int NOT NULL, rating numeric(3,1) NOT NULL)" \
    -c "INSERT INTO r SELECT g, 'title for row ' || g, g % 100000, ((g % 90) + 10) / 10.0 FROM generate_series(1, $ROWS) g" >/dev/null

  REPO="$WORK/git_$ROWS"
  rm -rf "$REPO"; mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email bench@example.com
  git -C "$REPO" config user.name bench
  git -C "$REPO" config gc.auto 0

  psql "$DSN" -X -q -At -c "COPY (SELECT id, title, votes, rating FROM r ORDER BY id) TO STDOUT" > "$REPO/data.tsv"
  BYTES=$(wc -c < "$REPO/data.tsv" | tr -d ' ')

  git -C "$REPO" add data.tsv
  T0=$(now_ms); git -C "$REPO" commit -q -m base; T1=$(now_ms)
  GIT_BASE=$((T1 - T0))

  q "SELECT pgit.track('r')" >/dev/null
  T0=$(now_ms); q "SELECT pgit.commit('base')" >/dev/null; T1=$(now_ms)
  PGIT_BASE=$((T1 - T0))

  GC=(); PC=(); GD=(); PD=()
  for i in $(seq 1 "$RUNS"); do
    q "UPDATE r SET votes = votes + 1 WHERE id IN (
         SELECT id FROM r ORDER BY (('x' || md5(id::text || '$i'))::bit(32)::int) LIMIT $CHANGED)" >/dev/null

    T0=$(now_ms); q "SELECT pgit.commit('change $i')" >/dev/null; T1=$(now_ms)
    PC+=($((T1 - T0)))

    psql "$DSN" -X -q -At -c "COPY (SELECT id, title, votes, rating FROM r ORDER BY id) TO STDOUT" > "$REPO/data.tsv"
    T0=$(now_ms); git -C "$REPO" commit -q -a -m "change $i"; T1=$(now_ms)
    GC+=($((T1 - T0)))

    T0=$(now_ms); git -C "$REPO" diff --stat HEAD~1 HEAD >/dev/null; T1=$(now_ms)
    GD+=($((T1 - T0)))

    T0=$(now_ms)
    q "SELECT count(*) FROM pgit.diff(pgit.rev('HEAD~1'), pgit.rev('HEAD'))" >/dev/null
    T1=$(now_ms)
    PD+=($((T1 - T0)))
  done

  GIT_COMMIT=$(median "${GC[@]}"); PGIT_COMMIT=$(median "${PC[@]}")
  GIT_DIFF=$(median "${GD[@]}");   PGIT_DIFF=$(median "${PD[@]}")

  git -C "$REPO" gc -q --aggressive 2>/dev/null
  GIT_STORE=$(du -sk "$REPO/.git" | cut -f1)
  q "SELECT pgit.repack()" >/dev/null
  psql "$DSN" -X -q -c "VACUUM FULL pgit.nodes" >/dev/null 2>&1
  PGIT_STORE=$(q "SELECT (pg_total_relation_size('pgit.nodes') + pg_total_relation_size('pgit.changes')) / 1024")

  win(){ if [ "$1" -lt "$2" ]; then echo "git $(echo "scale=1; $2/$1" | bc)x"; else echo "pgit $(echo "scale=1; $1/$2" | bc)x"; fi; }

  printf '%-10s %-22s %12s %12s %s\n' "$ROWS" "data size" "$((BYTES/1024)) kB" "$((BYTES/1024)) kB" ""
  printf '%-10s %-22s %12s %12s %s\n' "" "first commit" "${GIT_BASE}ms" "${PGIT_BASE}ms" "$(win $GIT_BASE $PGIT_BASE)"
  printf '%-10s %-22s %12s %12s %s\n' "" "commit $CHANGED rows" "${GIT_COMMIT}ms" "${PGIT_COMMIT}ms" "$(win $GIT_COMMIT $PGIT_COMMIT)"
  printf '%-10s %-22s %12s %12s %s\n' "" "diff one commit" "${GIT_DIFF}ms" "${PGIT_DIFF}ms" "$(win $GIT_DIFF $PGIT_DIFF)"
  printf '%-10s %-22s %12s %12s %s\n' "" "store after gc" "${GIT_STORE} kB" "${PGIT_STORE} kB" "$(win $GIT_STORE $PGIT_STORE)"
  echo
done

psql "$ADMIN" -X -q -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" >/dev/null 2>&1

echo "# git is timed on add plus commit of the already written file."
echo "# Writing that file from the table is pgit's job in this comparison and is not charged to git."
echo "# The pgit copy stays a queryable table throughout; the git copy is a TSV you must load to use."
