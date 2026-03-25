defmodule Cake.Repo.Migrations.CreateHexdocs do
  use Ecto.Migration

  def change do
    create table(:hexdocs, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :version, :string, null: false
      add :module, :string, null: false
      add :core, :boolean, default: false, null: false
      add :url, :string, null: false
      add :content, :text, null: false
      add :source, :string, default: "hexdocs", null: false
      add :language, :string, default: "elixir", null: false

      timestamps(type: :utc_datetime)
    end
  end
end
