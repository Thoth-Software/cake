defmodule Cake.Books.Chunk do
  use Cake.Schema
  import Ecto.Changeset
  import Ecto.Query

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
    :char_count          # ut supra
  """

  @derive {Jason.Encoder, except: [:__meta__, :parsed_book]}
  schema "chunks" do
    field :text, :string
    field :page_number, :integer
    field :chunk_index, :integer
    field :section_title, :string
    field :word_count, :integer
    field :char_count, :integer
    field :embedding, {:array, :float}

    belongs_to :parsed_book, Cake.Books.ParsedBook

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
    |> sanitize_text_fields()
  end

  def base_query(), do: from(c in __MODULE__)

  def by_book(query, parsed_book_id) do
    from c in query, where: c.parsed_book_id == ^parsed_book_id
  end

  def on_page(query, page_number) do
    from c in query, where: c.page_number == ^page_number
  end

  def within_pages(query, center_page, range) do
    first_page = center_page - range
    last_page = center_page + range

    from c in query,
      where: not is_nil(c.page_number),
      where: c.page_number >= ^first_page and c.page_number <= ^last_page
  end

  def by_section(query, section_title) do
    from c in query, where: c.section_title == ^section_title
  end
end
