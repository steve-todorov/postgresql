#!/usr/bin/env bash
#
# Smoke test for the CloudNativePG operand flavor image.
#
# The CNPG operand image has no standalone entrypoint (Cmd: bash) and does not
# auto-initdb. So we boot the container with a manual bootstrap: initdb a fresh
# datadir under /tmp, start postgres over a /tmp unix socket with pg_search
# preloaded, then run the same extension checks as scripts/smoke-test.sh.
#
# Usage:   scripts/smoke-test-cnpg.sh <image>
# Example: scripts/smoke-test-cnpg.sh ghcr.io/steve-todorov/postgresql:cnpg-18.4

set -euo pipefail

IMAGE="${1:?usage: $0 <image>}"
CONTAINER="cnpg-pg-smoke-$$"

info() { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# psql over the /tmp unix socket as the postgres superuser (trust auth).
psql_in()  { docker exec -i "$CONTAINER" psql -h /tmp -U postgres -d postgres -v ON_ERROR_STOP=1 -q; }
psql_val() { docker exec "$CONTAINER" psql -h /tmp -U postgres -d postgres -tAc "$1"; }
psql_run() { docker exec "$CONTAINER" psql -h /tmp -U postgres -d postgres -c "$1"; }

assert_eq() { [ "$1" = "$2" ] && ok "$3" || fail "$3 (expected '$2', got '$1')"; }
assert_contains() {
  case "$1" in
    *"$2"*) ok "$3" ;;
    *) printf '%s\n' "$1" >&2; fail "$3 (expected to find: $2)" ;;
  esac
}

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

start_container() {
  info "Starting container from $IMAGE (manual initdb + preload)"
  # Override the (bash) command with a bootstrap that initdb's, starts postgres
  # with pg_search preloaded, and stays alive. Runs as the image's default
  # user (26 / postgres). /tmp is writable and used for both PGDATA and socket.
  docker run -d --name "$CONTAINER" --entrypoint bash "$IMAGE" -c '
    set -e
    export PGDATA=/tmp/pgdata
    initdb -D "$PGDATA" --username=postgres --auth-local=trust --auth-host=trust >/dev/null
    pg_ctl -D "$PGDATA" -w \
      -o "-c shared_preload_libraries=pg_search -c unix_socket_directories=/tmp -c listen_addresses=" \
      start
    exec tail -f /dev/null
  ' >/dev/null

  printf '  waiting for PostgreSQL'
  for _ in $(seq 1 60); do
    if docker exec "$CONTAINER" pg_isready -h /tmp -U postgres >/dev/null 2>&1; then
      printf '\n'; ok "accepting connections"; return 0
    fi
    printf '.'; sleep 1
  done
  printf '\n'
  docker logs "$CONTAINER" >&2 || true
  fail "PostgreSQL did not become ready in time"
}

test_connection() {
  info "Connection"
  assert_eq "$(psql_val 'SELECT 1;')" "1" "can connect and run a query"
  ok "server version: $(psql_val 'SHOW server_version;')"
}

test_pgvector() {
  info "pgvector"
  assert_contains "$(psql_val "SELECT name FROM pg_available_extensions WHERE name = 'vector';")" \
    "vector" "extension is available in the image"
  psql_in <<'SQL'
SET client_min_messages = warning;
DROP TABLE IF EXISTS smoke_vector;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE TABLE smoke_vector (id bigserial PRIMARY KEY, embedding vector(3));
INSERT INTO smoke_vector (embedding)
  SELECT format('[%s,%s,%s]', g, g + 1, g + 2)::vector FROM generate_series(1, 50) AS g;
CREATE INDEX smoke_vector_hnsw ON smoke_vector USING hnsw (embedding vector_l2_ops);
SQL
  ok "extension enabled; table + HNSW index created"
  assert_eq "$(psql_val "SELECT extname FROM pg_extension WHERE extname = 'vector';")" \
    "vector" "extension is enabled (present in pg_extension)"
  assert_eq "$(psql_val "SELECT count(*) FROM (SELECT id FROM smoke_vector ORDER BY embedding <-> '[3,3,3]' LIMIT 5) q;")" \
    "5" "nearest-neighbour query returns rows"
  assert_contains \
    "$(psql_run "SET enable_seqscan = off; EXPLAIN SELECT id FROM smoke_vector ORDER BY embedding <-> '[3,3,3]' LIMIT 3;")" \
    "Index Scan using smoke_vector_hnsw" "EXPLAIN confirms the HNSW index is used"
}

test_locale() {
  info "libc locale (en_US.UTF-8)"
  # The image must carry en_US.UTF-8 so monolith imports that replay
  # `CREATE DATABASE ... LOCALE_PROVIDER = libc LOCALE 'en_US.UTF-8'`
  # (pg_dump --create) don't abort. `locale -a` reports it as en_US.utf8.
  assert_contains "$(docker exec "$CONTAINER" locale -a)" \
    "en_US.utf8" "en_US.UTF-8 locale is generated in the image"
  # Reproduce the exact statement a monolith restore replays.
  psql_run "CREATE DATABASE smoke_locale TEMPLATE template0 LOCALE_PROVIDER libc LOCALE 'en_US.UTF-8';" >/dev/null
  # Under the libc provider the locale lands in datcollate/datctype (datlocale
  # is ICU/builtin-only and NULL here).
  assert_eq "$(psql_val "SELECT datcollate FROM pg_database WHERE datname = 'smoke_locale';")" \
    "en_US.UTF-8" "CREATE DATABASE with libc LOCALE 'en_US.UTF-8' succeeds"
}

test_pg_search() {
  info "pg_search"
  assert_contains "$(psql_val 'SHOW shared_preload_libraries;')" \
    "pg_search" "pg_search is in shared_preload_libraries"
  assert_contains "$(psql_val "SELECT name FROM pg_available_extensions WHERE name = 'pg_search';")" \
    "pg_search" "extension is available in the image"
  psql_in <<'SQL'
SET client_min_messages = warning;
DROP TABLE IF EXISTS smoke_search;
CREATE EXTENSION IF NOT EXISTS pg_search;
CREATE TABLE smoke_search (id int PRIMARY KEY, body text);
INSERT INTO smoke_search (id, body) VALUES
  (1, 'hello world'),
  (2, 'postgres full text search'),
  (3, 'vectors and search engines');
CREATE INDEX smoke_search_bm25 ON smoke_search USING bm25 (id, body) WITH (key_field = 'id');
SQL
  ok "extension enabled; table + BM25 index created"
  assert_eq "$(psql_val "SELECT extname FROM pg_extension WHERE extname = 'pg_search';")" \
    "pg_search" "extension is enabled (present in pg_extension)"
  assert_eq "$(psql_val "SELECT id FROM smoke_search WHERE body @@@ 'postgres';")" \
    "2" "BM25 full-text query returns the matching row"
  local plan
  plan="$(psql_run "EXPLAIN SELECT id FROM smoke_search WHERE body @@@ 'postgres';")"
  assert_contains "$plan" "Custom Scan (ParadeDB" "EXPLAIN confirms the ParadeDB custom scan"
  assert_contains "$plan" "smoke_search_bm25" "EXPLAIN references the BM25 index"
}

main() {
  start_container
  test_connection
  test_locale
  test_pgvector
  test_pg_search
  info "All CNPG smoke tests passed"
}

main "$@"
