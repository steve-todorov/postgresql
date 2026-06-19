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

## Smoke test: boot a disposable container and verify both extensions work.
verify: build
	./scripts/smoke-test.sh $(IMAGE)

## Remove the compose stack and its named volume.
clean:
	docker compose down -v
