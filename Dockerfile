# syntax=docker/dockerfile:1

# Custom PostgreSQL image: official postgres + pg_search (ParadeDB) + pgvector.
#
# Both extensions are installed from version-matched packages, so their files
# land in the paths PostgreSQL expects for this major version automatically:
#   - control / SQL  -> /usr/share/postgresql/18/extension/
#   - shared objects -> /usr/lib/postgresql/18/lib/

FROM postgres:18.4-trixie

# --- Version pins -----------------------------------------------------------
# Bump deliberately. When PG_SEARCH_VERSION changes you MUST also update the
# sha256 in the `ADD --checksum` below, or the build will fail (by design).
ARG PG_MAJOR=18
ARG PG_DISTRO=trixie
ARG PG_SEARCH_VERSION=0.24.0
ARG PG_SEARCH_DEB_REVISION=1PARADEDB

# Pinned to an exact PGDG package version. The PGDG apt *index* keeps only the
# newest couple of versions; if this one ages out of the index the build will
# fail (the .deb persists in the PGDG pool and can be installed by direct URL).
ARG PGVECTOR_VERSION=0.8.2-1.pgdg13+1

# --- pgvector ---------------------------------------------------------------
# Installed from the PGDG apt repo already configured in the official image.
# Extension name in SQL is `vector`.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        "postgresql-${PG_MAJOR}-pgvector=${PGVECTOR_VERSION}" \
    && rm -rf /var/lib/apt/lists/*

# --- pg_search (ParadeDB) ---------------------------------------------------
# Pull the pinned, integrity-verified .deb straight from the GitHub release.
ADD --checksum=sha256:f99267a6533a02f077824938a29e80586415b301928d4499d01cb4a1b9c7ccca \
    "https://github.com/paradedb/paradedb/releases/download/v${PG_SEARCH_VERSION}/postgresql-${PG_MAJOR}-pg-search_${PG_SEARCH_VERSION}-${PG_SEARCH_DEB_REVISION}-${PG_DISTRO}_amd64.deb" \
    /tmp/pg_search.deb

# Install via apt (not bare `dpkg -i`) so runtime dependencies resolve.
RUN apt-get update \
    && apt-get install -y --no-install-recommends /tmp/pg_search.deb \
    && rm -f /tmp/pg_search.deb \
    && rm -rf /var/lib/apt/lists/*

# pg_search is a preload-required extension. Append the setting to the conf
# sample so every cluster initialized by this image bakes it into its
# generated postgresql.conf. (Does not affect pre-existing data dirs.)
RUN echo "shared_preload_libraries = 'pg_search'" >> /usr/share/postgresql/postgresql.conf.sample

LABEL org.opencontainers.image.title="postgresql-pg_search-pgvector" \
      org.opencontainers.image.description="PostgreSQL ${PG_MAJOR} with pg_search (ParadeDB ${PG_SEARCH_VERSION}) and pgvector" \
      org.opencontainers.image.source="https://github.com/steve-todorov/postgresql"
