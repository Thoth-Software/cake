defmodule Cake.Books.ParsedBook do
  @moduledoc """
  All data on a book besides the actual text, which is held in chunks.

  :metadata holds format-specific extras, e.g. PDF metadata dict, EPUB spine
  info, etc. This is better than adding a fuckload of nullable fields for every
  attribute under the sun.

  Justifications for non-obvious fields:
    :language is ISO language code, e.g. "en", "es", "fr", etc.
    :file_size is in bytes.
    :source_file_path is an object storage key (e.g. S3 key) or other path.
    :source_format is required because we pattern match on format to select chunking strategy.
    :file_hash is for deduplication

  Justifications for validate_required:
    :source_file_path,      # Always have this - where the file lives
    :source_format,         # Always know the format
    :file_hash,             # Always compute for deduplication
    :file_size,             # Always available from file system
    :title,                 # Should extract this at minimum
    :parsed_at,             # Set when parsing completes
    :embedding_status       # Has a default, but good to require

  """

  use Cake.Schema
  import Ecto.Changeset
  import Ecto.Query

  schema "parsed_books" do
    field :title, :string
    field :metadata, :map
    field :language, :string
    field :file_size, :integer
    field :source_file_path, :string
    field :authors, {:array, :string}
    field :source_format, :string
    field :file_hash, :string
    field :isbn, :string
    field :publisher, :string
    field :publication_date, :date
    field :total_pages, :integer
    field :word_count, :integer
    field :table_of_contents, :map
    field :parsed_at, :utc_datetime

    has_many :chunks, Cake.Books.Chunk

    field :embedding_status, Ecto.Enum,
      values: [:pending, :processing, :completed, :failed],
      default: :pending

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          title: String.t(),
          metadata: map() | nil,
          language: String.t() | nil,
          file_size: integer(),
          source_file_path: String.t(),
          authors: [String.t()] | nil,
          source_format: String.t(),
          file_hash: String.t(),
          isbn: String.t() | nil,
          publisher: String.t() | nil,
          publication_date: Date.t() | nil,
          total_pages: integer() | nil,
          word_count: integer(),
          table_of_contents: map() | nil,
          parsed_at: DateTime.t(),
          embedding_status: :pending | :processing | :completed | :failed,
          chunks: [Cake.Books.Chunk.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type book() :: %{
          title: String.t(),
          metadata: map(),
          language: String.t(),
          file_size: integer(),
          source_file_path: String.t(),
          authors: {:array, String.t()},
          source_format: String.t(),
          file_hash: String.t(),
          isbn: String.t(),
          publisher: String.t(),
          publication_date: Date.t(),
          total_pages: integer(),
          word_count: integer(),
          table_of_contents: map(),
          parsed_at: DateTime.t()
        }

  @doc false
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(parsed_book, attrs) do
    parsed_book
    |> cast(attrs, [
      :source_file_path,
      :source_format,
      :file_hash,
      :file_size,
      :title,
      :authors,
      :isbn,
      :publisher,
      :publication_date,
      :language,
      :total_pages,
      :word_count,
      :table_of_contents,
      :metadata,
      :parsed_at,
      :embedding_status
    ])
    |> validate_required([
      :source_file_path,
      :source_format,
      :file_hash,
      :file_size,
      :title,
      :word_count,
      :parsed_at,
      :embedding_status
    ])
    |> unique_constraint(:file_hash)
    |> sanitize_text_fields()
  end

  @spec base_query() :: Ecto.Query.t()
  def base_query(), do: from(c in __MODULE__)

  @spec by_title(Ecto.Query.t(), String.t()) :: Ecto.Query.t()
  def by_title(query, title) do
    from b in query, where: b.title == ^title
  end

  @spec by_language(Ecto.Query.t(), String.t()) :: Ecto.Query.t()
  def by_language(query, language) do
    from b in query, where: b.language == ^language
  end

  @spec by_file_path(Ecto.Query.t(), String.t()) :: Ecto.Query.t()
  def by_file_path(query, file_path) do
    from b in query, where: b.source_file_path == ^file_path
  end

  @spec by_author(Ecto.Query.t(), String.t()) :: Ecto.Query.t()
  def by_author(query, author) do
    from b in query, where: ^author in b.authors
  end

  @spec by_format(Ecto.Query.t(), String.t()) :: Ecto.Query.t()
  def by_format(query, format) do
    from b in query, where: b.source_format == ^format
  end

  @spec by_isbn(Ecto.Query.t(), String.t()) :: Ecto.Query.t()
  def by_isbn(query, isbn) do
    from b in query, where: b.isbn == ^isbn
  end

  @spec by_publisher(Ecto.Query.t(), String.t()) :: Ecto.Query.t()
  def by_publisher(query, publisher) do
    from b in query, where: b.publisher == ^publisher
  end

  @spec published_on(Ecto.Query.t(), Date.t()) :: Ecto.Query.t()
  def published_on(query, publication_date) do
    from b in query, where: b.publication_date == ^publication_date
  end

  @spec published_before(Ecto.Query.t(), Date.t()) :: Ecto.Query.t()
  def published_before(query, date) do
    from b in query, where: b.publication_date < ^date
  end

  @spec published_after(Ecto.Query.t(), Date.t()) :: Ecto.Query.t()
  def published_after(query, date) do
    from b in query, where: b.publication_date > ^date
  end

  @spec parsed_on(Ecto.Query.t(), DateTime.t()) :: Ecto.Query.t()
  def parsed_on(query, date) do
    from b in query, where: b.parsed_at == ^date
  end

  @spec parsed_before(Ecto.Query.t(), DateTime.t()) :: Ecto.Query.t()
  def parsed_before(query, date) do
    from b in query, where: b.parsed_at < ^date
  end

  @spec parsed_after(Ecto.Query.t(), DateTime.t()) :: Ecto.Query.t()
  def parsed_after(query, date) do
    from b in query, where: b.parsed_at > ^date
  end
end
