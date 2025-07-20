#!/bin/bash

# entrypoint.sh

#!/bin/bash
# Docker entrypoint script.

# Wait until Postgres is ready.
# while ! pg_isready -q -h $CAQUE_PGHOST -p $CAQUE_PGPORT -U $CAQUE_PGUSER
# while ! pg_isready -q -h $PGHOST -p $PGPORT -U $PGUSER
# do
#   echo "$(date) - waiting for database to start"
#   echo "PGHOST: $PGHOST PGPORT: $PGPORT  PGUSER: $PGUSER"
#   sleep 2
# done

# Run migrations, seed repo
# mix ecto.migrate
mix ecto.reset
mix run priv/repo/seeds.exs

exec elixir --sname dev -S mix phx.server
