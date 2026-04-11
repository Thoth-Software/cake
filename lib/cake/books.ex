defmodule Cake.Books do
  @moduledoc """
  The Books context.
  """

  require Logger
  import Ecto.Query, warn: false
  alias Cake.Repo

  alias Cake.Books.ParsedBook
  alias Cake.Books.Chunk

  def persist_book_and_chunks({%ParsedBook{file_hash: hash} = book, chunks})
      when is_list(chunks) do
    case Repo.one(from b in ParsedBook, where: b.file_hash == ^hash) do
      %ParsedBook{} = existing ->
        existing_chunks = Repo.all(from c in Chunk, where: c.parsed_book_id == ^existing.id)
        Logger.debug("Skipping already-persisted book #{existing.title} (#{hash})")
        {:ok, {existing, existing_chunks}}

      nil ->
        do_persist_book_and_chunks(book, chunks)
    end
  end

  def persist_book_and_chunks({book, chunks}) do
    {:error, {:invalid_input, %{book: book, chunks: chunks}}}
  end

  defp do_persist_book_and_chunks(book, chunks) do
    book_attrs =
      book
      |> Map.from_struct()
      |> Map.drop([:__meta__, :id, :inserted_at, :updated_at, :chunks])

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:book, ParsedBook.changeset(%ParsedBook{}, book_attrs))
      |> Ecto.Multi.run(:chunks, fn repo, %{book: persisted_book} ->
        chunks
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {chunk, idx}, {:ok, acc} ->
          chunk_attrs =
            chunk
            |> Map.from_struct()
            |> Map.drop([:__meta__, :id, :inserted_at, :updated_at, :parsed_book])
            |> Map.put(:parsed_book_id, persisted_book.id)
            |> Map.put_new(:chunk_index, idx)

          cs = Chunk.changeset(%Chunk{}, chunk_attrs)

          if cs.valid? do
            row =
              cs.changes
              |> Map.put(:inserted_at, now)
              |> Map.put(:updated_at, now)

            {:cont, {:ok, [row | acc]}}
          else
            {:halt, {:error, {:invalid_chunk, cs.errors, chunk_attrs}}}
          end
        end)
        |> case do
          {:ok, reversed_rows} ->
            chunk_rows = Enum.reverse(reversed_rows)

            {count, returned_rows} =
              repo.insert_all(Chunk, chunk_rows,
                returning: [
                  :id,
                  :parsed_book_id,
                  :page_number,
                  :chunk_index,
                  :section_title,
                  :text,
                  :word_count,
                  :char_count
                ]
              )

            if count == length(chunk_rows) do
              {:ok, returned_rows}
            else
              {:error, {:chunk_insert_count_mismatch, count, length(chunk_rows)}}
            end

          {:error, _reason} = error ->
            error
        end
      end)

    case Repo.transaction(multi) do
      {:ok, %{book: persisted_book, chunks: persisted_chunks}} ->
        {:ok, {persisted_book, persisted_chunks}}

      {:error, _step, reason, _changes_so_far} ->
        {:error, {book.source_file_path, reason}}
    end
  end

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
  Updates a chunk.

  ## Examples

      iex> update_chunk!(chunk, %{field: new_value})
      {:ok, %Chunk{}}

      iex> update_chunk!(chunk, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_chunk!(%Chunk{} = chunk, attrs) do
    chunk
    |> Chunk.changeset(attrs)
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

  alias Cake.Books.Chunk

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
  Fetches Chunk records for a list of OpenSearch hits, with `parsed_book`
  preloaded. Returns chunks in the same order as the hits.
  """
  def chunks_for_hits(hits) do
    ids = Enum.map(hits, fn hit -> hit.source["id"] end)

    chunks_by_id =
      Repo.all(from c in Chunk, where: c.id in ^ids, preload: :parsed_book)
      |> Map.new(fn chunk -> {chunk.id, chunk} end)

    ids
    |> Enum.map(&Map.get(chunks_by_id, &1))
    |> Enum.reject(&is_nil/1)
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
