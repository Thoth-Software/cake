defmodule Cake.Repo.Migrations.AddUsernameToUsers do
  use Ecto.Migration

  # A user logs in with a username (#372). `username` is `citext`, so it is
  # compared case-insensitively and stored as typed; it is required and
  # unique. `email` stays, keeps its unique index, and becomes optional.
  #
  # There is no backfill. Cake is in alpha and nothing is deployed: by the
  # time a database holds users worth keeping, this column will always have
  # been there. So on a database that already has users, migrating up fails
  # ("column \"username\" of relation \"users\" contains null values") and
  # the database is reset instead: `mix ecto.reset`, or `docker compose down
  # -v` for the dev stack, whose seed then recreates its login.
  #
  # Rolling back makes `email` required again, so it fails in the same way
  # while any user has no email.
  def change do
    alter table(:users) do
      add :username, :citext, null: false
      modify :email, :citext, null: true, from: {:citext, null: false}
    end

    create unique_index(:users, [:username])
  end
end
