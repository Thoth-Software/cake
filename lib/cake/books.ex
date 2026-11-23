defmodule Cake.Books do
  @moduledoc """
  The Books context.
  """

  use Boundary,
    top_level?: true,
    deps: [Cake, Cake.Search, Cake.Embeddings, Cake.Pipelines],
    exports: [Adapters, ParsedBook, Chunk, Pipeline, Pdf.Pipeline, ZipExtractor]

  import Ecto.Query, only: [from: 2]

  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Repo

  @doc """
  Returns the list of parsed_books.

  ## Examples

      iex> list_parsed_books()
      [%ParsedBook{}, ...]

  """
  @spec list_parsed_books() :: [ParsedBook.t()]
  def list_parsed_books do
    Repo.all(ParsedBook)
  end

  # The fields the documents list shows.
  @listed_fields [:id, :title, :total_pages, :embedding_status, :inserted_at, :source_file_path]

  @typedoc """
  One book as the documents list shows it: the six fields that list needs
  and no others. A plain map, not a `t:Cake.Books.ParsedBook.t/0`, so that
  nothing takes it for a whole book.
  """
  @type parsed_book_listing :: %{
          id: Ecto.UUID.t(),
          title: String.t(),
          total_pages: integer() | nil,
          embedding_status: :pending | :processing | :completed | :failed,
          inserted_at: DateTime.t(),
          source_file_path: String.t()
        }

  @doc """
  Returns a listing of every parsed_book, newest upload first: by
  `inserted_at` descending.

  This is the read behind the documents list. It is read whole, so it loads
  only the fields that list shows, as a `t:parsed_book_listing/0`: the
  `metadata` and `table_of_contents` maps of a book can be large and are
  left unread. Use `get_parsed_book!/1` for a complete book.

  `inserted_at` is stored to the second, and the books of one batch upload
  land within one, so books that share a time are ordered by `id`: the
  order is the same on every read.

  ## Examples

      iex> list_parsed_books_newest_first()
      [%{id: "...", title: "Annual Report", ...}, ...]

  """
  @spec list_parsed_books_newest_first() :: [parsed_book_listing()]
  def list_parsed_books_newest_first do
    Repo.all(
      from b in ParsedBook,
        select: map(b, ^@listed_fields),
        order_by: [desc: b.inserted_at, asc: b.id]
    )
  end

  @doc """
  Returns how many chunks the given parsed_book has.

  ## Examples

      iex> count_chunks(parsed_book)
      42

  """
  @spec count_chunks(ParsedBook.t()) :: non_neg_integer()
  def count_chunks(%ParsedBook{id: id}) do
    Repo.aggregate(from(c in Chunk, where: c.parsed_book_id == ^id), :count)
  end

  @doc """
  Gets a single parsed_book.

  Raises `Ecto.NoResultsError` if the Parsed book does not exist, and
  `Ecto.Query.CastError` if `id` is not a UUID.

  ## Examples

      iex> get_parsed_book!("7c2b0f6e-5d4a-4c1b-9f3e-2a1b0c9d8e7f")
      %ParsedBook{}

      iex> get_parsed_book!("00000000-0000-0000-0000-000000000000")
      ** (Ecto.NoResultsError)

  """
  @spec get_parsed_book!(binary()) :: ParsedBook.t()
  def get_parsed_book!(id), do: Repo.get!(ParsedBook, id)

  @doc """
  Creates a parsed_book.

  ## Examples

      iex> create_parsed_book(%{field: value})
      {:ok, %ParsedBook{}}

      iex> create_parsed_book(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec create_parsed_book(map()) :: {:ok, ParsedBook.t()} | {:error, Ecto.Changeset.t()}
  def create_parsed_book(attrs \\ %{}) do
    %ParsedBook{}
    |> ParsedBook.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a parsed_book.

  ## Examples

      iex> update_parsed_book(parsed_book, %{field: new_value})
      {:ok, %ParsedBook{}}

      iex> update_parsed_book(parsed_book, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec update_parsed_book(ParsedBook.t(), map()) ::
          {:ok, ParsedBook.t()} | {:error, Ecto.Changeset.t()}
  def update_parsed_book(%ParsedBook{} = parsed_book, attrs) do
    parsed_book
    |> ParsedBook.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a parsed_book.

  ## Examples

      iex> delete_parsed_book(parsed_book)
      {:ok, %ParsedBook{}}

      iex> delete_parsed_book(parsed_book)
      {:error, %Ecto.Changeset{}}

  """
  @spec delete_parsed_book(ParsedBook.t()) ::
          {:ok, ParsedBook.t()} | {:error, Ecto.Changeset.t()}
  def delete_parsed_book(%ParsedBook{} = parsed_book) do
    Repo.delete(parsed_book)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking parsed_book changes.

  ## Examples

      iex> change_parsed_book(parsed_book)
      %Ecto.Changeset{data: %ParsedBook{}}

  """
  @spec change_parsed_book(ParsedBook.t(), map()) :: Ecto.Changeset.t()
  def change_parsed_book(%ParsedBook{} = parsed_book, attrs \\ %{}) do
    ParsedBook.changeset(parsed_book, attrs)
  end

  @doc """
  Returns the list of chunks.

  ## Examples

      iex> list_chunks()
      [%Chunk{}, ...]

  """
  @spec list_chunks() :: [Chunk.t()]
  def list_chunks do
    Repo.all(Chunk)
  end

  @doc """
  Gets a single chunk.

  Raises `Ecto.NoResultsError` if the Chunk does not exist, and
  `Ecto.Query.CastError` if `id` is not a UUID.

  ## Examples

      iex> get_chunk!("7c2b0f6e-5d4a-4c1b-9f3e-2a1b0c9d8e7f")
      %Chunk{}

      iex> get_chunk!("00000000-0000-0000-0000-000000000000")
      ** (Ecto.NoResultsError)

  """
  @spec get_chunk!(binary()) :: Chunk.t()
  def get_chunk!(id), do: Repo.get!(Chunk, id)

  @doc """
  Creates a chunk.

  ## Examples

      iex> create_chunk(%{field: value})
      {:ok, %Chunk{}}

      iex> create_chunk(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec create_chunk(map()) :: {:ok, Chunk.t()} | {:error, Ecto.Changeset.t()}
  def create_chunk(attrs \\ %{}) do
    %Chunk{}
    |> Chunk.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a chunk.

  ## Examples

      iex> update_chunk(chunk, %{field: new_value})
      {:ok, %Chunk{}}

      iex> update_chunk(chunk, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec update_chunk(Chunk.t(), map()) :: {:ok, Chunk.t()} | {:error, Ecto.Changeset.t()}
  def update_chunk(%Chunk{} = chunk, attrs) do
    chunk
    |> Chunk.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a chunk.

  ## Examples

      iex> delete_chunk(chunk)
      {:ok, %Chunk{}}

      iex> delete_chunk(chunk)
      {:error, %Ecto.Changeset{}}

  """
  @spec delete_chunk(Chunk.t()) :: {:ok, Chunk.t()} | {:error, Ecto.Changeset.t()}
  def delete_chunk(%Chunk{} = chunk) do
    Repo.delete(chunk)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking chunk changes.

  ## Examples

      iex> change_chunk(chunk)
      %Ecto.Changeset{data: %Chunk{}}

  """
  @spec change_chunk(Chunk.t(), map()) :: Ecto.Changeset.t()
  def change_chunk(%Chunk{} = chunk, attrs \\ %{}) do
    Chunk.changeset(chunk, attrs)
  end
end
