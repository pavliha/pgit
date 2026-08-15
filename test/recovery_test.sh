#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"

if ! command -v docker >/dev/null 2>&1; then
  echo "recovery: docker not available, skipping"
  exit 0
fi

NAME="${RECOVERY_CONTAINER:-pgit-recovery}"
PORT="${RECOVERY_PORT:-5463}"
PG="${RECOVERY_PG:-18}"
KILLS="${RECOVERY_KILLS:-4}"
H="localhost:$PORT"
ADMIN="postgresql://postgres:pgit@$H/postgres"
D="postgresql://postgres:pgit@$H/pgit_rec"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker build --build-arg PG="$PG" -t "$NAME-img" "$DIR/../docker" >/dev/null 2>&1
docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=pgit -e POSTGRES_DB=pgit_test \
  -e TZ=UTC -e PGTZ=UTC -p "$PORT:5432" "$NAME-img" >/dev/null

wait_ready() {
  for _ in $(seq 1 90); do
    docker exec "$NAME" pg_isready -U postgres -d pgit_test >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

if ! wait_ready; then nok "recovery: server never became ready"; suite_end RECOVERY 1; fi

psql "$ADMIN" -X -q -c "CREATE DATABASE pgit_rec" >/dev/null 2>&1
psql "$D" -X -q -v ON_ERROR_STOP=1 -f "$DIR/../sql/install.sql" >/dev/null 2>&1
psql "$D" -X -q -c "CREATE TABLE r (id int PRIMARY KEY, v text, n int)" >/dev/null
psql "$D" -X -q -At -c "SELECT pgit.track('r')" >/dev/null
psql "$D" -X -q -c "INSERT INTO r SELECT g,'v'||g,0 FROM generate_series(1,20000) g" >/dev/null
psql "$D" -X -q -At -c "SELECT pgit.commit('base','main')" >/dev/null

BEFORE=$(psql "$D" -X -At -c "SELECT encode(pgit.resolve('main'),'hex')")

recovered=0
violations=0
for i in $(seq 1 "$KILLS"); do
  case $((i % 4)) in
    0) WORK="UPDATE r SET n = n + $i WHERE id % 3 = 0; SELECT pgit.commit('k$i','main');" ;;
    1) WORK="UPDATE r SET v = 'k$i' WHERE id % 5 = 0; SELECT pgit.commit('k$i','main'); SELECT pgit.repack();" ;;
    2) WORK="DELETE FROM r WHERE id = $((500 + i)); SELECT pgit.commit('k$i','main');" ;;
    *) WORK="INSERT INTO r SELECT g,'n$i',1 FROM generate_series($((30000 + i*100)), $((30000 + i*100 + 200))) g; SELECT pgit.commit('k$i','main');" ;;
  esac

  psql "$D" -X -q -c "$WORK" >/dev/null 2>&1 &
  WORKER=$!
  sleep "0.$(( 2 + RANDOM % 6 ))"

  docker kill -s SIGKILL "$NAME" >/dev/null 2>&1
  wait "$WORKER" 2>/dev/null
  docker start "$NAME" >/dev/null 2>&1

  if ! wait_ready; then
    nok "recovery: server did not come back after kill $i"
    violations=$((violations + 1))
    continue
  fi
  recovered=$((recovered + 1))

  BAD=$(psql "$D" -X -At -c "
    SELECT (SELECT count(*) FROM pgit.fsck())
         + (SELECT count(*) FROM pgit.trees t
            WHERE t.commit_sha = pgit.resolve('main')
              AND pgit.write_tree(t.tbl::regclass) IS DISTINCT FROM t.root_hash)" 2>&1)
  if [ "$BAD" != "0" ]; then
    violations=$((violations + 1))
    echo "  kill $i: invariants broken after recovery (fsck+mismatch = $BAD)"
  fi
done

is "recovery: the server came back from every SIGKILL" "$recovered" "$KILLS"
is "recovery: every recovery left fsck clean and every tree matching a rebuild" "$violations" "0"

is "recovery: no uncommitted journal rows survived the crashes" \
   "$(psql "$D" -X -At -c "SELECT count(*) FROM pgit.changes WHERE commit_sha IS NULL")" "0"

AFTER=$(psql "$D" -X -At -c "SELECT encode(pgit.resolve('main'),'hex')")
isnt "recovery: committed work before the crashes was not lost" "$AFTER" ""

is "recovery: the branch still resolves to a real commit" \
   "$(psql "$D" -X -At -c "SELECT count(*) FROM pgit.commits WHERE sha = pgit.resolve('main')")" "1"

psql "$D" -X -q -c "UPDATE r SET n = n + 1 WHERE id = 1" >/dev/null
is "recovery: pgit still commits after all of it" \
   "$(psql "$D" -X -At -c "SELECT (pgit.commit('after recovery','main') IS NOT NULL)" | tail -1)" "t"

is "recovery: and that commit's tree matches a rebuild" \
   "$(psql "$D" -X -At -c "SELECT pgit.write_tree('r') = (SELECT root_hash FROM pgit.trees WHERE commit_sha = pgit.resolve('main') AND tbl = 'r')")" "t"

suite_end RECOVERY 7
