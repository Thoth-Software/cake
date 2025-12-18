defmodule Caque.Books do
  @moduledoc """
  The Books context.
  """

  import Ecto.Query, warn: false
  alias Caque.Repo

  alias Caque.Books.ParsedBook

  @doc """
  Returns the list of parsed_books.

  ## Examples

      iex> list_parsed_books()
      [%ParsedBook{}, ...]

  """
  def list_parsed_books do
    Repo.all(ParsedBook)
  end

  @doc """
  Gets a single parsed_book.

  Raises `Ecto.NoResultsError` if the Parsed book does not exist.

  ## Examples

      iex> get_parsed_book!(123)
      %ParsedBook{}

      iex> get_parsed_book!(456)
      ** (Ecto.NoResultsError)

  """
  def get_parsed_book!(id), do: Repo.get!(ParsedBook, id)

  @doc """
  Creates a parsed_book.

  ## Examples

      iex> create_parsed_book(%{field: value})
      {:ok, %ParsedBook{}}

      iex> create_parsed_book(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
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
  def delete_parsed_book(%ParsedBook{} = parsed_book) do
    Repo.delete(parsed_book)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking parsed_book changes.

  ## Examples

      iex> change_parsed_book(parsed_book)
      %Ecto.Changeset{data: %ParsedBook{}}

  """
  def change_parsed_book(%ParsedBook{} = parsed_book, attrs \\ %{}) do
    ParsedBook.changeset(parsed_book, attrs)
  end

  alias Caque.Books.Chunk

  @doc """
  Returns the list of chunks.

  ## Examples

      iex> list_chunks()
      [%Chunk{}, ...]

  """
  def list_chunks do
    Repo.all(Chunk)
  end

  @doc """
  Gets a single chunk.

  Raises `Ecto.NoResultsError` if the Chunk does not exist.

  ## Examples

      iex> get_chunk!(123)
      %Chunk{}

      iex> get_chunk!(456)
      ** (Ecto.NoResultsError)

  """
  def get_chunk!(id), do: Repo.get!(Chunk, id)

  @doc """
  Creates a chunk.

  ## Examples

      iex> create_chunk(%{field: value})
      {:ok, %Chunk{}}

      iex> create_chunk(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
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
  def delete_chunk(%Chunk{} = chunk) do
    Repo.delete(chunk)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking chunk changes.

  ## Examples

      iex> change_chunk(chunk)
      %Ecto.Changeset{data: %Chunk{}}

  """
  def change_chunk(%Chunk{} = chunk, attrs \\ %{}) do
    Chunk.changeset(chunk, attrs)
  end
end
