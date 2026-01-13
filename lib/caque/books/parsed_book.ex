defmodule Caque.Books.ParsedBook do
  use Caque.Schema
  import Ecto.Changeset

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

    has_many :chunks, Caque.Books.Chunk

    field :embedding_status, Ecto.Enum,
      values: [:pending, :processing, :completed, :failed],
      default: :pending

    timestamps(type: :utc_datetime)
  end

  @doc false
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
  end

  def base_query(), do: from(c in __MODULE__)

  def by_title(query, title) do
    from b in query, where: b.title == ^title
  end

  def by_language(query, language_code) do
    from b in query, where: b.language_code == ^language
  end

  def by_file_path(query, file_path) do
    from b in query, where: b.file_path == ^file_path
  end

  def by_author(query, author) do
    from b in query, where: ^author in b.authors
  end

  def by_format(query, format) do
    from b in query, where: b.source_format == ^format
  end
         
  def by_isbn(query, isbn) do
    from b in query, where: b.isbn == ^isbn
  end

  def by_publisher(query, publisher) do
    from b in query, where: b.publisher == ^publisher
  end

  def published_on(query, publication_date) do
    from b in query, where: b.publication_date == ^publication_date
  end

  def published_before(query, date) do
    from b in query, where: b.publication_date < ^date
  end

  def published_after(query, date) do
    from b in query, where: b.publication_date > ^date
  end

  def parsed_on(query, date) do
    from b in query, where: b.parsed_at == ^date)
  end

  def parsed_before(query, date) do
    from b in query, where: b.parsed_at < ^date
  end

  def parsed_after(query, date) do
    from b in query, where: b.parsed_at > ^date
  end

  end
