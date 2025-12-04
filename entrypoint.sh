#!/usr/bin/env bash
set -e

# Ensure we’re in the app directory (WORKDIR should already be /app, but be explicit)
cd /app

# --- Optional: wait for OpenSearch (keeps your earlier race condition dead) ---
OPENSEARCH_URL="${OPENSEARCH_URL:-http://opensearch:9200}"

echo "Waiting for OpenSearch at: $OPENSEARCH_URL"
attempt=1
while true; do
  if curl -s "$OPENSEARCH_URL/_cluster/health" \
    | grep -E '"status":"(yellow|green)"' > /dev/null 2>&1; then
    echo "OpenSearch is up (cluster health yellow/green)."
    break
  fi

  echo "OpenSearch not ready yet (attempt $attempt). Sleeping..."
  attempt=$((attempt + 1))
  sleep 5
done

# --- Make sure deps/lock are in sync inside the container ---
echo "Running mix deps.get..."
mix deps.get

# --- DB bootstrapping (dev-only destructive reset) ---
# echo "Resetting DB..."
# mix ecto.reset

echo "Running migrations..."
mix ecto.migrate

echo "Seeding DB..."
mix run priv/repo/seeds.exs

echo "Starting Phoenix..."
exec elixir --sname dev -S mix phx.server

