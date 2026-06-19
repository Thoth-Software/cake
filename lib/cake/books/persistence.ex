defmodule Cake.Books.Persistence do
  @moduledoc """
  Write-path for the Books GDS: persists a parsed book and its chunks in a
  single transaction, deduplicating by `file_hash`.

  Separated from the `Cake.Books` CRUD context because this is bespoke ingest
  logic (hash dedup, `Ecto.Multi`, bulk `insert_all` with a count check) used
  by `Cake.Books.Pipeline`, not generic record management.
  """

  import Ecto.Query, warn: false

  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Repo

  require Logger

  @spec persist_books_and_chunks({ParsedBook.t(), [Chunk.t()]} | {term(), term()}) ::
          {:ok, {ParsedBook.t(), [Chunk.t()]}} | {:error, any()}
  def persist_books_and_chunks({%ParsedBook{file_hash: hash} = book, chunks})
      when is_list(chunks) do
    case Repo.one(from b in ParsedBook, where: b.file_hash == ^hash) do
      %ParsedBook{} = existing ->
        existing_chunks = Repo.all(from c in Chunk, where: c.parsed_book_id == ^existing.id)
        Logger.debug("Skipping already-persisted book #{existing.title} (#{hash})")
        {:ok, {existing, existing_chunks}}

      nil ->
        persist_books_and_chunks(book, chunks)
    end
  end

  def persist_books_and_chunks({book, chunks}) do
    {:error, {:invalid_input, %{book: book, chunks: chunks}}}
  end

  @spec persist_books_and_chunks(ParsedBook.t(), [Chunk.t()]) ::
          {:ok, {ParsedBook.t(), [Chunk.t()]}} | {:error, any()}
  def persist_books_and_chunks(%ParsedBook{} = book, chunks) when is_list(chunks) do
    book
    |> build_multi(chunks)
    |> run_transaction(book)
  end

  defp build_multi(book, chunks) do
    book_attrs =
      book
      |> Map.from_struct()
      |> Map.drop([:__meta__, :id, :inserted_at, :updated_at, :chunks])

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:book, ParsedBook.changeset(%ParsedBook{}, book_attrs))
    |> Ecto.Multi.run(:chunks, fn repo, %{book: persisted_book} ->
      insert_chunks(repo, persisted_book, chunks)
    end)
  end

  defp insert_chunks(repo, persisted_book, chunks) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    chunks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {chunk, idx}, {:ok, acc} ->
      case build_chunk_row(chunk, persisted_book.id, idx, now) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, reversed_rows} -> bulk_insert_chunks(repo, Enum.reverse(reversed_rows))
      {:error, _} = error -> error
    end)
  end

  defp build_chunk_row(chunk, book_id, idx, now) do
    chunk_attrs =
      chunk
      |> Map.from_struct()
      |> Map.drop([:__meta__, :id, :inserted_at, :updated_at, :parsed_book])
      |> Map.put(:parsed_book_id, book_id)
      # Persist-time position is the single source of truth for ordering, so
      # chunk_index is always dense (0..N-1) regardless of upstream gaps.
      |> Map.put(:chunk_index, idx)

    cs = Chunk.changeset(%Chunk{}, chunk_attrs)

    if cs.valid? do
      row =
        cs.changes
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)

      {:ok, row}
    else
      {:error, {:invalid_chunk, cs.errors, chunk_attrs}}
    end
  end

  defp bulk_insert_chunks(repo, chunk_rows) do
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
  end

  defp run_transaction(multi, book) do
    case Repo.transaction(multi) do
      {:ok, %{book: persisted_book, chunks: persisted_chunks}} ->
        {:ok, {persisted_book, persisted_chunks}}

      {:error, _step, reason, _changes_so_far} ->
        {:error, {book.source_file_path, reason}}
    end
  end
end
