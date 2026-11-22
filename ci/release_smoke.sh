#!/usr/bin/env bash
#
# ci/release_smoke.sh -- release image smoke test (#361).
#
# Builds the release image from Dockerfile.release and probes it for what no
# other gate sees. ci/compose_smoke.sh gates the dev image (Dockerfile +
# entrypoint.sh: MIX_ENV=dev, a recompile at boot, `mix phx.server`); this
# gates the image that is deployed: a `mix release` built in a builder stage
# and copied into a runner stage that has no Mix, no compiler and no Rust.
#
# Booting the app is NOT asserted here. The release cannot boot in prod until
# the production runtime config lands (#362: the search node, the object
# store and the endpoint are not configurable at runtime yet). What is
# asserted is everything short of boot, through one-shot commands that load
# the release's code and runtime config without starting the application.
#
# The image is built from Dockerfile.release first; a build that fails is the
# first finding. Then the checks, in order (each is a `check_*` function
# listed in `checks` below):
#   1. nif         `bin/cake eval` extracts a fixture PDF through
#                  Cake.ParseBooks.extract_pdf/1: the parsebooks NIF was
#                  compiled in the builder stage, was carried into the runner
#                  stage inside the release, and loads there (the runner's
#                  libc and libstdc++ satisfy it). The fixture is bind-mounted
#                  read-only: a release image carries no test/.
#   2. migrations  `bin/migrate` (Cake.Release.migrate/0) against a Postgres
#                  container applies every migration under
#                  priv/repo/migrations.
#
# Adding a check: write a `check_<name>` function that calls `fail` when the
# image is wrong, and add `<name>` to `checks`. The helpers a check is built
# from are `release` (a one-shot command in the release image, on the smoke
# network, with the prod environment), `release_eval` (an Elixir expression
# through `bin/cake eval`) and `db_query` (SQL against the smoke database,
# which the migrations check has migrated by then and nothing has seeded).
#
# Everything the script creates (the Postgres container and the network) is
# removed on exit, success or failure; on failure the Postgres log is printed
# first, if Postgres was started. The built image is left in the local image store, where it is the
# next run's layer cache. RELEASE_SMOKE_KEEP=1 leaves the container and the
# network up for a look around.
#
# Knobs (all optional):
#   RELEASE_SMOKE_IMAGE          tag given to the built image (default
#                                cake-release-smoke).
#   RELEASE_SMOKE_PROJECT        prefix of the container and network names
#                                (default cake-release-smoke), so a run never
#                                touches a developer's own stack.
#   RELEASE_SMOKE_DOCKERFILE     the Dockerfile to build (default
#                                Dockerfile.release). BuildKit reads the
#                                build-context ignore file from beside it,
#                                `<Dockerfile>.dockerignore`.
#   RELEASE_SMOKE_BUILD_OPTS     extra `docker build` options, split on
#                                whitespace (default none). For machines whose
#                                builds need a proxy or a host network; CI
#                                passes nothing.
#   RELEASE_SMOKE_POSTGRES_IMAGE the Postgres image (default postgres:14, the
#                                release docker-compose.yml and the CI service
#                                containers run).
#   RELEASE_SMOKE_DB_TIMEOUT     seconds to wait for Postgres to accept
#                                connections (default 120).

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

RELEASE_SMOKE_IMAGE="${RELEASE_SMOKE_IMAGE:-cake-release-smoke}"
RELEASE_SMOKE_PROJECT="${RELEASE_SMOKE_PROJECT:-cake-release-smoke}"
RELEASE_SMOKE_DOCKERFILE="${RELEASE_SMOKE_DOCKERFILE:-Dockerfile.release}"
RELEASE_SMOKE_BUILD_OPTS="${RELEASE_SMOKE_BUILD_OPTS:-}"
RELEASE_SMOKE_POSTGRES_IMAGE="${RELEASE_SMOKE_POSTGRES_IMAGE:-postgres:14}"
RELEASE_SMOKE_DB_TIMEOUT="${RELEASE_SMOKE_DB_TIMEOUT:-120}"

# The checks, in the order they run against the built image. `migrations`
# leaves the smoke database migrated, so a check that reads the schema goes
# after it.
checks=(nif migrations)

network="$RELEASE_SMOKE_PROJECT"
db_container="$RELEASE_SMOKE_PROJECT-db"
db_user=postgres
db_password=postgres
db_name=cake_release_smoke

# The fixture PDF the NIF check extracts: the happy-path fixture from the NIF
# integration suite (three text pages, nothing skipped), the one
# ci/compose_smoke.sh uses. Mounted into the container at fixture_mount.
fixture_dir=test/support/fixtures/pdfs
fixture_mount=/fixtures
nif_fixture=multi_page.pdf

# What config/runtime.exs demands of any prod VM, `bin/cake eval` included:
# it raises when one of these is unset. Only DATABASE_URL is ever used here
# (by bin/migrate); the rest are placeholders that are not shaped like real
# credentials, and SECRET_KEY_BASE is made up per run, so nothing checked in
# can be mistaken for a secret. What the app needs to *boot* is #362's.
release_env=(
  --env "DATABASE_URL=ecto://$db_user:$db_password@$db_container/$db_name"
  --env "SECRET_KEY_BASE=$(head -c 48 /dev/urandom | base64 | tr -d '\n')"
  --env "OPENAI_KEY=release-smoke-placeholder-not-a-key"
  --env "BOOK_STORAGE_S3_BUCKET=release-smoke-placeholder-bucket"
)

poll_interval=2

log() { printf '==> %s\n' "$*"; }

fail() {
  printf '!! %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local status=$?
  trap - EXIT

  if [ "$status" -ne 0 ]; then
    log "Release smoke test failed (exit $status)"

    if docker container inspect "$db_container" >/dev/null 2>&1; then
      log "The Postgres log follows"
      docker logs --tail 100 "$db_container" 2>&1 || true
    fi
  fi

  if [ "${RELEASE_SMOKE_KEEP:-0}" = "1" ]; then
    log "RELEASE_SMOKE_KEEP=1: leaving $db_container and the $network network up"
  else
    log "Removing the Postgres container and the network"
    docker rm --force --volumes "$db_container" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
  fi

  exit "$status"
}
trap cleanup EXIT

# wait_until TIMEOUT WHAT CMD... -- polls CMD until it succeeds; fails the run
# once TIMEOUT seconds have passed.
wait_until() {
  local timeout=$1 what=$2
  shift 2
  local deadline=$((SECONDS + timeout))

  until "$@"; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      fail "Timed out after ${timeout}s waiting until $what"
    fi
    sleep "$poll_interval"
  done

  log "$what"
}

# release CMD... -- runs CMD once in a fresh container of the release image,
# as the image's own user, on the smoke network, with the prod environment
# and the fixtures mounted read-only.
release() {
  docker run --rm --network "$network" "${release_env[@]}" \
    --volume "$PWD/$fixture_dir:$fixture_mount:ro" \
    "$RELEASE_SMOKE_IMAGE" "$@"
}

# release_eval EXPR -- evaluates an Elixir expression in the release: code and
# runtime config loaded, the application not started. A raise is a non-zero
# exit.
release_eval() {
  release bin/cake eval "$1"
}

# db_query SQL -- one unaligned, tuples-only result from the smoke database.
db_query() {
  docker exec "$db_container" psql -U "$db_user" -d "$db_name" -tAc "$1"
}

# Over TCP on purpose: the postgres image runs its init scripts on a temporary
# server that listens on the unix socket only, so a socket probe would report
# ready before the real server is up.
db_ready() {
  docker exec "$db_container" pg_isready --quiet -h 127.0.0.1 -U "$db_user" -d "$db_name"
}

start_db() {
  log "Starting Postgres ($RELEASE_SMOKE_POSTGRES_IMAGE)"
  docker rm --force --volumes "$db_container" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker network create "$network" >/dev/null

  docker run --detach --name "$db_container" --network "$network" \
    --env "POSTGRES_USER=$db_user" \
    --env "POSTGRES_PASSWORD=$db_password" \
    --env "POSTGRES_DB=$db_name" \
    "$RELEASE_SMOKE_POSTGRES_IMAGE" >/dev/null

  wait_until "$RELEASE_SMOKE_DB_TIMEOUT" "Postgres accepts connections" db_ready
}

build_image() {
  local build_opts=()
  read -r -a build_opts <<<"$RELEASE_SMOKE_BUILD_OPTS"

  log "Building $RELEASE_SMOKE_IMAGE from $RELEASE_SMOKE_DOCKERFILE"
  docker build "${build_opts[@]}" \
    --file "$RELEASE_SMOKE_DOCKERFILE" --tag "$RELEASE_SMOKE_IMAGE" . ||
    fail "The release image does not build from $RELEASE_SMOKE_DOCKERFILE"
  log "The release image builds"
}

# The match is the assertion: the fixture has three text pages and nothing
# skipped, so anything else (an error tuple, a NIF that does not load, a
# different page count) raises and the eval exits non-zero.
check_nif() {
  local expr
  expr=$(
    cat <<ELIXIR
path = "$fixture_mount/$nif_fixture"
{:ok, %{pages: [_, _, _], skipped: []}} = path |> File.read!() |> Cake.ParseBooks.extract_pdf()
IO.puts("NIF ok: " <> path <> ": 3 pages extracted, 0 skipped")
ELIXIR
  )

  release_eval "$expr" ||
    fail "The parsebooks NIF did not extract $nif_fixture inside the release image"
  log "The parsebooks NIF loads inside the release image"
}

# Every migration file must be recorded as applied: a count equal to the number
# of migrations under priv/repo/migrations (<timestamp>_<name>.exs; the
# directory's .formatter.exs is not one), not merely non-zero.
check_migrations() {
  local expected applied

  release bin/migrate || fail "bin/migrate failed in the release image"

  expected=$(find priv/repo/migrations -name '[0-9]*_*.exs' | wc -l | tr -d '[:space:]')
  applied=$(db_query "SELECT count(*) FROM schema_migrations" | tr -d '[:space:]')

  [ "$applied" = "$expected" ] ||
    fail "Expected $expected migrations in schema_migrations, found '$applied'"
  log "bin/migrate applied all $applied migrations"
}

# The image is built before Postgres is started: a build failure is the
# likeliest one, and it needs no database to report.
build_image
start_db

for check in "${checks[@]}"; do
  "check_$check"
done

log "Release smoke test passed"
