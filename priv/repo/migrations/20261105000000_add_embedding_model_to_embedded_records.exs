defmodule Cake.Repo.Migrations.AddEmbeddingModelToEmbeddedRecords do
  use Ecto.Migration

  # The model that produced each row's `embedding`, written in the same
  # update as the vector (#284). Nullable: rows embedded before this column
  # existed load `nil`, which `Cake.Books.Persistence` reads as "not known to
  # be the requested model", so re-ingesting their bytes resumes them rather
  # than skipping them as duplicates. No dimension column: the dimension is
  # the stored vector's length, and a second copy of it could only disagree.
  def change do
    alter table(:chunks) do
      add :embedding_model, :string
    end

    alter table(:parsed_documents) do
      add :embedding_model, :string
    end
  end
end
