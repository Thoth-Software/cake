defmodule Cake.Repo.Migrations.CreateChunks do
  use Ecto.Migration

  def change do
    create table(:chunks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :page_number, :integer
      add :chunk_index, :integer
      add :section_title, :string
      add :text, :text
      add :word_count, :integer
      add :char_count, :integer
      add :embedding, {:array, :float}
      add :parsed_book_id, references(:parsed_books, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:chunks, [:parsed_book_id])
  end
end
