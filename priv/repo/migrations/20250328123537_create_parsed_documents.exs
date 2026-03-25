defmodule Cake.Repo.Migrations.CreateParsedDocuments do
  use Ecto.Migration

  def change do
    create table(:parsed_documents, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :source, :text
      add :version, :text
      add :package, :text
      add :title, :text
      add :url, :text
      add :text, :text
      add :language, :text
      add :core, :boolean
      add :embedding, {:array, :float}

      timestamps(type: :utc_datetime)
    end
  end
end
