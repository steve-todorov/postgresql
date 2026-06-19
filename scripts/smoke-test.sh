#!/usr/bin/env bash
#
# Smoke test for the custom PostgreSQL image.
#
# Boots a throwaway container from the given image and runs one test function
# per extension. Each function checks the same simple things:
#   1. the extension is available in the image
#   2. it can be enabled (CREATE EXTENSION)
#   3. a real query using it works
#   4. EXPLAIN proves the extension's index/scan is actually used (not a fallback)
#
# Usage:   scripts/smoke-test.sh <image>
# Example: scripts/smoke-test.sh ghcr.io/steve-todorov/postgresql:main

set -euo pipefail

IMAGE="${1:?usage: $0 <image>}"
PG_USER="${POSTGRES_USER:-postgres}"
PG_DB="${POSTGRES_DB:-postgres}"
PG_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
CONTAINER="bf-pg-smoke-$$"

# --- output helpers ---------------------------------------------------------

info() { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# --- psql helpers -----------------------------------------------------------

# Run SQL piped from stdin; stops on the first error.
psql_in()  { docker exec -i "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 -q; }
# Run one statement, return its bare value (tuples-only, unaligned).
psql_val() { docker exec "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tAc "$1"; }
# Run one statement, return its full output (used for EXPLAIN inspection).
psql_run() { docker exec "$CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -c "$1"; }

# --- assertions -------------------------------------------------------------

assert_eq() { # actual expected description
  [ "$1" = "$2" ] && ok "$3" || fail "$3 (expected '$2', got '$1')"
}

assert_contains() { # haystack needle description
  case "$1" in
    *"$2"*) ok "$3" ;;
    *) printf '%s\n' "$1" >&2; fail "$3 (expected to find: $2)" ;;
  esac
}

# --- container lifecycle ----------------------------------------------------

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

start_container() {
  info "Starting container from $IMAGE"
  docker run -d --rm \
    -e POSTGRES_PASSWORD="$PG_PASSWORD" \
    -e POSTGRES_USER="$PG_USER" \
    -e POSTGRES_DB="$PG_DB" \
    --name "$CONTAINER" "$IMAGE" >/dev/null
  printf '  waiting for PostgreSQL'
  for _ in $(seq 1 60); do
    if docker exec "$CONTAINER" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
      printf '\n'; ok "accepting connections"; return 0
    fi
    printf '.'; sleep 1
  done
  printf '\n'; fail "PostgreSQL did not become ready in time"
}

# --- tests ------------------------------------------------------------------

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

  # Force the index over a tiny-table seqscan so EXPLAIN is deterministic.
  assert_contains \
    "$(psql_run "SET enable_seqscan = off; EXPLAIN SELECT id FROM smoke_vector ORDER BY embedding <-> '[3,3,3]' LIMIT 3;")" \
    "Index Scan using smoke_vector_hnsw" "EXPLAIN confirms the HNSW index is used"
}

test_pg_search() {
  info "pg_search"
  # Preload is mandatory; without it the extension cannot load at all.
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

# --- main -------------------------------------------------------------------

main() {
  start_container
  test_connection
  test_pgvector
  test_pg_search
  info "All smoke tests passed"
}

main "$@"
