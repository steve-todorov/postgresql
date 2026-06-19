# Centralized pins — keep in sync with the Dockerfile ARG defaults.
PG_MAJOR            ?= 18
PG_SEARCH_VERSION   ?= 0.24.0
IMAGE               ?= postgresql-pg_search-pgvector:local

.PHONY: build run up down psql verify clean

## Build the image locally.
build:
	docker build \
		--build-arg PG_MAJOR=$(PG_MAJOR) \
		--build-arg PG_SEARCH_VERSION=$(PG_SEARCH_VERSION) \
		-t $(IMAGE) .

## Run a throwaway container in the foreground (Ctrl-C to stop).
run: build
	docker run --rm -e POSTGRES_PASSWORD=postgres -p 5432:5432 $(IMAGE)

## Bring the compose stack up / down.
up:
	docker compose up --build -d

down:
	docker compose down

## Open a psql shell against the compose service.
psql:
	docker compose exec postgres psql -U $${POSTGRES_USER:-postgres} -d $${POSTGRES_DB:-postgres}

## Smoke test: boot a disposable container, create both extensions, prove they load.
verify: build
	docker run --rm -e POSTGRES_PASSWORD=postgres --name pg-verify -d $(IMAGE) >/dev/null
	@echo "Waiting for PostgreSQL to become ready..."
	@until docker exec pg-verify pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
	@echo "--- creating extensions ---"
	docker exec pg-verify psql -U postgres -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS pg_search;"
	docker exec pg-verify psql -U postgres -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS vector;"
	@echo "--- installed extensions ---"
	docker exec pg-verify psql -U postgres -c "SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_search','vector');"
	@echo "--- pgvector smoke ---"
	docker exec pg-verify psql -U postgres -c "SELECT '[1,2,3]'::vector <-> '[3,2,1]'::vector AS l2_distance;"
	docker stop pg-verify >/dev/null
	@echo "OK: both extensions load."

## Remove the compose stack and its named volume.
clean:
	docker compose down -v
