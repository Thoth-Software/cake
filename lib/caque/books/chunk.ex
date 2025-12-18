defmodule Caque.Books.Chunk do
  use Caque.Schema
  import Ecto.Changeset

  @moduledoc """
  A searchable chunk of a book. These go onto the OpenSearch instance as documents.

  Justifications for non-obvious fields:
    :page_number is nullable since some formats lack pages.
    :chunk_index provides ordering for unpaginated formats and cases lacking a page <-> chunk bijection.
    :word_count and :char_count allow for token count estimation that we can relate to LLM context windows

  Justifications for validate_required:
    :parsed_book_id,     # Every chunk must belong to a book
    :chunk_index,        # Needed for ordering
    :text,               # The actual content - can't have empty chunks
    :word_count,         # Computed from text, always available
    :char_count          # Computed from text, always available
  """

  schema "chunks" do
    field :text, :string
    field :page_number, :integer
    field :chunk_index, :integer
    field :section_title, :string
    field :word_count, :integer
    field :char_count, :integer
    field :embedding, {:array, :float}

    belongs_to :parsed_book, Caque.Books.ParsedBook

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [
      :parsed_book_id,
      :page_number,
      :chunk_index,
      :section_title,
      :text,
      :word_count,
      :char_count
    ])
    |> validate_required([
      :parsed_book_id,
      :chunk_index,
      :text,
      :word_count,
      :char_count
    ])
    |> foreign_key_constraint(:parsed_book_id)
  end
end
