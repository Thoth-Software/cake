defmodule Cake.Repo.Migrations.CreateParsedBooks do
  use Ecto.Migration

  def change do
    create table(:parsed_books, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_format, :string
      add :source_file_path, :string
      add :file_hash, :string
      add :file_size, :integer
      add :title, :string
      add :authors, {:array, :string}
      add :isbn, :string
      add :publisher, :string
      add :publication_date, :date
      add :language, :string
      add :total_pages, :integer
      add :word_count, :integer
      add :table_of_contents, :map
      add :metadata, :map
      add :parsed_at, :utc_datetime
      add :embedding_status, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:parsed_books, [:file_hash])
  end
end
