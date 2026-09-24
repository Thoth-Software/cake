#!/usr/bin/env bash
#
# ci/compose_smoke.sh -- docker-compose smoke test (#250).
#
# Builds the compose stack from the checked-in Dockerfile, boots it through
# entrypoint.sh, and probes the running containers for what the ExUnit suite
# cannot see: Phoenix runs `server: false` in test, so Cake.Application's
# supervision order and Cake.Search.Deployment's boot-time collection creation
# are exercised nowhere else, and the NIF-clobbering recompile sequence lives
# in entrypoint.sh, where only a broken container ever surfaced a regression.
# The `integration` job tests the code inside service containers; this script
# tests the containers themselves, so it doubles as the executable record of
# the deployment topology.
#
# Assertions, in order:
#   1. db and opensearch report healthy (their compose health checks).
#   2. The app answers HTTP 200 through the published port.
#   3. Both search collections exist in OpenSearch (Deployment boot ran).
#   4. Every migration under priv/repo/migrations is in schema_migrations.
#
# The stack is torn down (`docker compose down -v`) on exit, success or
# failure; on failure the container logs are printed first. SMOKE_KEEP=1
# leaves the stack running for a look around.
#
# Knobs (all optional):
#   SMOKE_PROJECT              compose project name (default cake-smoke). The
#                              project name namespaces containers, network and
#                              volumes, so the `down -v` here never touches a
#                              developer's own `docker compose up` stack.
#   SMOKE_APP_URL              URL probed for HTTP 200 (default
#                              http://localhost:4000/, the port docker-compose.yml
#                              publishes).
#   SMOKE_HEALTH_TIMEOUT       seconds to wait for db + opensearch health
#                              (default 300).
#   SMOKE_BOOT_TIMEOUT         seconds to wait for the app's first HTTP 200
#                              (default 1500: entrypoint.sh recompiles the app
#                              and the NIF before starting Phoenix).
#   SMOKE_COLLECTIONS_TIMEOUT  seconds to wait for the collections after the app
#                              answers (default 120: Deployment creates them 10s
#                              after boot).

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SMOKE_PROJECT="${SMOKE_PROJECT:-cake-smoke}"
SMOKE_APP_URL="${SMOKE_APP_URL:-http://localhost:4000/}"
SMOKE_HEALTH_TIMEOUT="${SMOKE_HEALTH_TIMEOUT:-300}"
SMOKE_BOOT_TIMEOUT="${SMOKE_BOOT_TIMEOUT:-1500}"
SMOKE_COLLECTIONS_TIMEOUT="${SMOKE_COLLECTIONS_TIMEOUT:-120}"

compose=(docker compose --project-name "$SMOKE_PROJECT")

# The collections Cake.Search.Deployment creates at boot: the
# `:search_collections` entries in config/config.exs, by their
# `collection_name/0` (Cake.Books.ParsedBook and Cake.Documents.ParsedDocument).
collections=(chunks_of_books docs)

poll_interval=5

log() { printf '==> %s\n' "$*"; }

fail() {
  printf '!! %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local status=$?
  trap - EXIT

  if [ "$status" -ne 0 ]; then
    log "Smoke test failed (exit $status); container logs follow"
    "${compose[@]}" logs --no-color --tail=300 || true
  fi

  if [ "${SMOKE_KEEP:-0}" = "1" ]; then
    log "SMOKE_KEEP=1: leaving the stack up (tear down with: ${compose[*]} down -v)"
  else
    log "Tearing down the stack"
    "${compose[@]}" down --volumes --remove-orphans || true
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

container_id() {
  "${compose[@]}" ps --quiet --all "$1"
}

# healthy SERVICE -- the service's compose health check reports healthy. An
# `unhealthy` status is not a failure here: OpenSearch's first checks run before
# it is listening, and Docker keeps checking, so the status flips once a probe
# passes. The deadline in wait_until bounds that.
healthy() {
  local status
  status=$(docker inspect --format '{{.State.Health.Status}}' "$(container_id "$1")" 2>/dev/null) || return 1
  [ "$status" = "healthy" ]
}

# Fails at once when the app container has exited: waiting out the boot
# timeout would only hide entrypoint.sh's error under a timeout message.
app_alive() {
  local state
  state=$(docker inspect --format '{{.State.Status}}' "$(container_id phoenix)" 2>/dev/null) ||
    fail "The phoenix container does not exist"
  [ "$state" = "running" ] ||
    fail "The phoenix container is '$state': entrypoint.sh did not bring the app up"
}

app_answers() {
  app_alive
  [ "$(curl --silent --output /dev/null --write-out '%{http_code}' "$SMOKE_APP_URL")" = "200" ]
}

# collection_exists NAME -- asked through the opensearch container, so the
# check needs no OpenSearch port on the host.
collection_exists() {
  local code
  code=$("${compose[@]}" exec -T opensearch \
    curl --silent --output /dev/null --write-out '%{http_code}' "http://localhost:9200/$1")
  [ "$code" = "200" ]
}

log "Building the stack"
"${compose[@]}" build

log "Starting the stack"
"${compose[@]}" up --detach

wait_until "$SMOKE_HEALTH_TIMEOUT" "db is healthy" healthy db
wait_until "$SMOKE_HEALTH_TIMEOUT" "opensearch is healthy" healthy opensearch
wait_until "$SMOKE_BOOT_TIMEOUT" "the app answers HTTP 200 at $SMOKE_APP_URL" app_answers

for name in "${collections[@]}"; do
  wait_until "$SMOKE_COLLECTIONS_TIMEOUT" "collection '$name' exists in OpenSearch" \
    collection_exists "$name"
done

# Every migration file must be recorded as applied: a count equal to the number
# of migrations under priv/repo/migrations (<timestamp>_<name>.exs; the
# directory's .formatter.exs is not one), not merely non-zero.
expected_migrations=$(find priv/repo/migrations -name '[0-9]*_*.exs' | wc -l | tr -d '[:space:]')
applied_migrations=$("${compose[@]}" exec -T db \
  sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT count(*) FROM schema_migrations"' |
  tr -d '[:space:]')

[ "$applied_migrations" = "$expected_migrations" ] ||
  fail "Expected $expected_migrations migrations in schema_migrations, found '$applied_migrations'"
log "All $applied_migrations migrations applied"

log "Smoke test passed"
