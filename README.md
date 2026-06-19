# PostgreSQL + pg_search + pgvector

A custom PostgreSQL image that extends the [official `postgres`](https://hub.docker.com/_/postgres) image and adds two extensions, installed from version-matched packages so their files land in the paths PostgreSQL expects:

- **[pg_search](https://github.com/paradedb/paradedb)** (ParadeDB) — BM25 full-text search. SQL name: `pg_search`.
- **[pgvector](https://github.com/pgvector/pgvector)** — vector similarity search. SQL name: `vector`.

## What's in the image

| Component | Source | Version |
|-----------|--------|---------|
| Base image | `postgres:18.4-trixie` (Debian 13, PostgreSQL 18.4) | 18.4 |
| pg_search | Pinned `.deb` from the [GitHub release](https://github.com/paradedb/paradedb/releases/tag/v0.24.0), integrity-checked via `ADD --checksum` | 0.24.0 |
| pgvector | [PGDG apt repo](https://wiki.postgresql.org/wiki/Apt) (`postgresql-18-pgvector`), pinned to an exact package version | 0.8.2-1.pgdg13+1 |
| Architecture | `linux/amd64` only | — |

Files install to the canonical locations for PG 18:

- extension control + SQL → `/usr/share/postgresql/18/extension/`
- shared objects → `/usr/lib/postgresql/18/lib/`

## Important: pg_search requires preloading

`pg_search` only works when loaded via `shared_preload_libraries`. The image appends `shared_preload_libraries = 'pg_search'` to `/usr/share/postgresql/postgresql.conf.sample`, so **every cluster initialized by this image** bakes the setting into its generated `postgresql.conf` automatically.

This applies only to data directories *initialized by this image*. If you mount a pre-existing data directory created without this setting, set it yourself and restart, e.g.:

```sql
ALTER SYSTEM SET shared_preload_libraries = 'pg_search';
-- then restart the server
```

`pgvector` needs no preload.

## Usage

The image installs the binaries only — create the extensions per database yourself:

```sql
CREATE EXTENSION IF NOT EXISTS pg_search;
CREATE EXTENSION IF NOT EXISTS vector;
```

### Build and run locally

```bash
make build          # build the image
make run            # run a throwaway container on :5432
# or use compose:
cp .env.example .env
make up             # build + start in the background
make psql           # open a psql shell
make verify         # smoke test: create both extensions and prove they load
make down           # stop the stack
make clean          # stop and remove the data volume
```

### Pull from GHCR

Published by CI to the GitHub Container Registry:

```bash
docker pull ghcr.io/steve-todorov/postgresql:latest
```

## Bumping versions

- **pg_search**: update `PG_SEARCH_VERSION` in the `Dockerfile` (and `Makefile`), then update the `sha256` in the `ADD --checksum=…` line to match the new `.deb`. Get it with:
  ```bash
  curl -fsSL https://github.com/paradedb/paradedb/releases/download/v<VER>/postgresql-18-pg-search_<VER>-1PARADEDB-trixie_amd64.deb | sha256sum
  ```
  A stale checksum fails the build by design — that is the integrity guard, not a bug.
- **pgvector**: pinned via `PGVECTOR_VERSION` (an exact PGDG package version, e.g. `0.8.2-1.pgdg13+1`). List currently-indexed versions with `apt-cache madison postgresql-18-pgvector`. The PGDG index keeps only the newest couple of versions; if your pin ages out, the `.deb` still lives in the [PGDG pool](http://apt.postgresql.org/pub/repos/apt/pool/main/p/pgvector/) and can be installed by direct URL.
- **PostgreSQL major / base distro**: change the `FROM` tag, `PG_MAJOR`, and `PG_DISTRO`. pg_search ships `.deb`s for PG 15–18 and bookworm/noble/trixie; the package name embeds both.

## CI

`.github/workflows/build-publish.yml` builds and pushes to `ghcr.io/<owner>/<repo>` on:

- push to `main` → `latest` + branch tag + git SHA
- version tags `v*` → semver tags (`1.2.3`, `1.2`)
- manual `workflow_dispatch`

It authenticates with the built-in `GITHUB_TOKEN` (`packages: write`); no extra secrets required.
