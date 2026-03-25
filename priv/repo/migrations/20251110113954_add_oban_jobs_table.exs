# What is `version: 15` doing here? Should it stay that way?`
defmodule Cake.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  def up do
    Oban.Migration.up()
  end

  def down do
    Oban.Migration.down()
  end
end
