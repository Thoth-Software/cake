defmodule Cake.Books.Chunk do
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

  use Cake.Schema
  import Ecto.Changeset
  import Ecto.Query

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

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          text: String.t(),
          page_number: integer() | nil,
          chunk_index: integer(),
          section_title: String.t() | nil,
          word_count: integer(),
          char_count: integer(),
          embedding: [float()] | nil,
          parsed_book_id: Ecto.UUID.t(),
          parsed_book: Cake.Books.ParsedBook.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc false
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [
      :parsed_book_id,
      :embedding,
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

  @spec base_query() :: Ecto.Query.t()
  def base_query(), do: from(c in __MODULE__)

  @spec by_book(Ecto.Query.t(), binary()) :: Ecto.Query.t()
  def by_book(query, parsed_book_id) do
    from c in query, where: c.parsed_book_id == ^parsed_book_id
  end

  @spec on_page(Ecto.Query.t(), integer()) :: Ecto.Query.t()
  def on_page(query, page_number) do
    from c in query, where: c.page_number == ^page_number
  end

  @spec within_pages(Ecto.Query.t(), integer(), integer()) :: Ecto.Query.t()
  def within_pages(query, center_page, range) do
    first_page = center_page - range
    last_page = center_page + range

    from c in query,
      where: not is_nil(c.page_number),
      where: c.page_number >= ^first_page and c.page_number <= ^last_page
  end

  @spec by_section(Ecto.Query.t(), String.t()) :: Ecto.Query.t()
  def by_section(query, section_title) do
    from c in query, where: c.section_title == ^section_title
  end
end

defimpl Cake.Citable, for: Cake.Books.Chunk do
  alias Cake.Books.ParsedBook

  @preview_length 200

  @doc """
  Builds citation metadata for a Books.Chunk.

  Requires that `:parsed_book` be preloaded; pattern-matches on
  `%ParsedBook{}` in the association slot and will raise `FunctionClauseError`
  if the association is `%Ecto.Association.NotLoaded{}`. This is intentional —
  missing preload at this layer is a caller bug and should crash loudly under
  supervision rather than silently producing garbage metadata.
  """
  @spec metadata(Cake.Books.Chunk.t()) :: Cake.Citable.metadata()
  def metadata(%@for{parsed_book: %ParsedBook{} = book} = chunk) do
    %{
      id: chunk.id,
      label: format_label(book.title, chunk.page_number, chunk.section_title),
      preview: String.slice(chunk.text, 0, @preview_length),
      source_ref: book.source_file_path,
      extras: %{
        book_title: book.title,
        page_number: chunk.page_number,
        section_title: chunk.section_title,
        chunk_index: chunk.chunk_index
      }
    }
  end

  defp format_label(title, nil, nil), do: title
  defp format_label(title, page, nil), do: "#{title}, p. #{page}"
  defp format_label(title, nil, section), do: "#{title} — #{section}"
  defp format_label(title, page, section), do: "#{title}, p. #{page} — #{section}"
end
