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
#   3. host_nif    Nothing from the host's priv/native is in the release. The
#                  script plants a marker file there before building (planted,
#                  below), as a host-built NIF would lie there; the release's
#                  priv/native must hold parsebooks.so and nothing else. That
#                  passes only while Dockerfile.release.dockerignore or the
#                  Dockerfile's own `rm` keeps the directory out.
#   4. no_seeds    No seeds.exs anywhere in the release (/app): priv/repo/seeds.exs
#                  creates a login whose password is in the repo, and a
#                  release that does not carry the file cannot run it.
#
# Adding a check: write a `check_<name>` function that calls `fail` when the
# image is wrong, and add `<name>` to `checks`. The helpers a check is built
# from are `release` (a one-shot command in the release image, on the smoke
# network, with the prod environment), `release_eval` (an Elixir expression
# through `bin/cake eval`) and `db_query` (SQL against the smoke database,
# which the migrations check has migrated by then and nothing has seeded).
#
# Everything the script creates (the Postgres container, the network and the
# planted marker file) is removed on exit, success or failure; on failure the Postgres log is printed
# first, if Postgres was started. The built image is left in the local image store, where it is the
# next run's layer cache. RELEASE_SMOKE_KEEP=1 leaves the container and the
# network up for a look around (the marker file is removed all the same).
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
#                                version that docker-compose.yml and the CI
#                                service containers run).
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
checks=(nif migrations host_nif no_seeds)

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

# The marker planted in the build context before the build (check_host_nif).
# priv/native is where Rustler writes the NIF and is gitignored, so a fresh
# checkout has none and a developer's has their host-built parsebooks.so. The
# marker is a second file there, under a name nothing else uses: Rustler would
# overwrite a planted parsebooks.so when it compiles the crate, and the check
# could not tell.
host_nif_dir=priv/native
host_nif_marker=release-smoke-planted-host-nif.so
created_host_nif_dir=0

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

  rm -f "$host_nif_dir/$host_nif_marker"
  if [ "$created_host_nif_dir" = "1" ]; then
    rmdir "$host_nif_dir" 2>/dev/null || true
  fi

  if [ "${RELEASE_SMOKE_KEEP:-0}" = "1" ]; then
    if docker container inspect "$db_container" >/dev/null 2>&1; then
      log "RELEASE_SMOKE_KEEP=1: leaving $db_container and the $network network up"
    else
      log "RELEASE_SMOKE_KEEP=1: nothing to leave up (Postgres was never started)"
    fi
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

# Plants the marker check_host_nif looks for. Removed by cleanup, with the
# directory if this created it.
plant_host_nif() {
  if [ ! -d "$host_nif_dir" ]; then
    mkdir -p "$host_nif_dir"
    created_host_nif_dir=1
  fi

  printf 'planted by ci/release_smoke.sh; must never reach the release image\n' \
    >"$host_nif_dir/$host_nif_marker"
  log "Planted $host_nif_dir/$host_nif_marker in the build context"
}

build_image() {
  local build_opts=()
  read -r -a build_opts <<<"$RELEASE_SMOKE_BUILD_OPTS"

  log "Building $RELEASE_SMOKE_IMAGE from $RELEASE_SMOKE_DOCKERFILE"
  # ${arr[@]+...}: bash before 4.4 (macOS ships 3.2) treats expanding an empty
  # array as an unbound variable under `set -u`.
  docker build ${build_opts[@]+"${build_opts[@]}"} \
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

# The release's priv/native is searched by name, not by a fixed path, because
# the path carries the app's version (lib/cake-<vsn>/priv/native).
check_host_nif() {
  local found

  found=$(release sh -c 'find /app/lib -path "*/cake-*/priv/native/*" | sort') ||
    fail "Could not list the release's priv/native"

  # Exactly one file, and it is the NIF the builder stage compiled.
  case "$found" in
    *$'\n'*) fail "Files from the host's $host_nif_dir reached the release image: $(printf '%s' "$found" | tr '\n' ' ')" ;;
    */priv/native/parsebooks.so) ;;
    *) fail "The release's priv/native should hold parsebooks.so and nothing else, found: ${found:-nothing}" ;;
  esac

  log "Nothing from the host's $host_nif_dir is in the release"
}

check_no_seeds() {
  local found

  # /app is the whole release (the runner stage copies nothing else in), and
  # all of it is readable by the image's user.
  found=$(release find /app -name 'seeds.exs') ||
    fail "Could not search the release image for seeds.exs"
  [ -z "$found" ] || fail "The release image carries a seeds file: $found"
  log "The release image carries no seeds.exs"
}

# The image is built before Postgres is started: a build failure is the
# likeliest one, and it needs no database to report.
plant_host_nif
build_image
start_db

for check in "${checks[@]}"; do
  "check_$check"
done

log "Release smoke test passed"
