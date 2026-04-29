defmodule Cake.Repo.Migrations.CreateParsedBooks do
  use Ecto.Migration

  def change do
    create table(:parsed_books, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # Always required - enforced at DB level
      add :source_file_path, :string, null: false
      add :source_format, :string, null: false
      add :file_hash, :string, null: false
      add :file_size, :integer, null: false
      add :title, :string, null: false
      add :word_count, :integer, null: false
      add :parsed_at, :utc_datetime, null: false
      add :embedding_status, :string, null: false, default: "pending"

      # Optional metadata fields
      add :authors, {:array, :string}
      add :isbn, :string
      add :publisher, :string
      add :publication_date, :date
      add :language, :string
      add :total_pages, :integer
      add :table_of_contents, :map
      add :metadata, :map

      timestamps(type: :utc_datetime)
    end

    create unique_index(:parsed_books, [:file_hash])
  end
end
