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
  Expands a list of retrieved chunks by fetching neighboring chunks from Postgres.

  Given chunks returned by `chunks_for_hits/1`, this function:
  1. Groups them by `parsed_book_id`
  2. For each book, computes the union of chunk index ranges [index - offset, index + offset]
  3. Merges overlapping ranges to avoid redundant queries
  4. Fetches all chunks in those ranges from Postgres
  5. Returns a deduplicated, ordered list with `:parsed_book` preloaded

  The offset controls how many chunks on each side of a hit are included.
  An offset of 2 means each hit brings in up to 4 neighbors (2 before, 2 after),
  though in practice overlapping hits within the same book will merge into
  contiguous windows.

  ## Examples

      # Expand each hit by 2 chunks on each side
      chunks = Books.chunks_for_hits(hits)
      expanded = Books.expand_with_neighbors(chunks, 2)

  """
  @spec expand_with_neighbors([Chunk.t()], non_neg_integer()) :: [Chunk.t()]
  def expand_with_neighbors(chunks, offset) when is_list(chunks) and is_integer(offset) and offset >= 0 do
    chunks
    |> Enum.group_by(& &1.parsed_book_id)
    |> Enum.flat_map(fn {book_id, book_chunks} ->
      ranges =
        book_chunks
        |> Enum.map(fn c -> {max(c.chunk_index - offset, 0), c.chunk_index + offset} end)
        |> Enum.sort()
        |> merge_ranges()

      Enum.flat_map(ranges, fn {low, high} ->
        Chunk.base_query()
        |> Chunk.by_book(book_id)
        |> where([c], c.chunk_index >= ^low and c.chunk_index <= ^high)
        |> order_by([c], asc: c.chunk_index)
        |> Repo.all()
        |> Repo.preload(:parsed_book)
      end)
    end)
    |> Enum.uniq_by(& &1.id)
  end

  # Merges a sorted list of {low, high} integer ranges into non-overlapping ranges.
  # Adjacent ranges (e.g., {1, 3} and {4, 6}) are also merged since chunk indices
  # are integers and index 3 and index 4 are contiguous.
  defp merge_ranges([]), do: []

  defp merge_ranges([first | rest]) do
    Enum.reduce(rest, [first], fn {low, high}, [{acc_low, acc_high} | tail] ->
      if low <= acc_high + 1 do
        [{acc_low, max(acc_high, high)} | tail]
      else
        [{low, high}, {acc_low, acc_high} | tail]
      end
    end)
    |> Enum.reverse()
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
