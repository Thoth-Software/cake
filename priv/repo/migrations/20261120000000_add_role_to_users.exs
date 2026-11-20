defmodule Cake.Repo.Migrations.AddRoleToUsers do
  use Ecto.Migration

  # A user is a member or an admin (#373). The column carries the default
  # itself, so a row that names no role is a member: the rows a database
  # already holds, and any written without going through `Cake.Accounts`.
  # That is also why this migration needs no backfill and no reset, unlike
  # the username one before it.
  #
  # The values are checked by `Ecto.Enum` in `Cake.Accounts.User`, not by a
  # database type: adding a role later is then a code change and no migration.
  def change do
    alter table(:users) do
      add :role, :string, null: false, default: "member"
    end
  end
end
