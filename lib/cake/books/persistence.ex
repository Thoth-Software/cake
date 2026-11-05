defmodule Cake.Books.Persistence do
  @moduledoc """
  Write-path for the Books GDS: persists a parsed book and its chunks in a
  single transaction, deduplicating by `file_hash` and embedding model. A
  book whose bytes are already persisted *and ingested under the requested
  model* — `embedding_status` `:completed`, which `Cake.Books.Pipeline`
  writes only after every chunk is embedded and accepted by the index, and
  every chunk's `embedding_model` equal to the model the caller is
  ingesting with — is reported as `{:duplicate, existing}` rather than
  inserted, so the pipeline skips it. Any other book behind the hash is one
  the requested model has not finished: a status of `:pending`,
  `:processing` or `:failed` (an earlier run did not finish), or a
  `:completed` book whose chunks carry another model or none (`nil`: rows
  embedded before the column existed, #284). Its existing rows come back as
  `{:ok, {existing, chunks}}` so the pipeline resumes it, and resuming
  first clears every vector not produced by the requested model, so a
  chunk whose re-embed then fails cannot keep a stale vector beside
  siblings embedded under the new one. The row is committed before any
  chunk is embedded, which is why the status, not the row's existence,
  decides; and nothing records who owns a `:processing` book, which is why
  it is resumable.

  Separated from the `Cake.Books` CRUD context because this is bespoke ingest
  logic (hash dedup, `Ecto.Multi`, bulk `insert_all` with a count check) used
  by `Cake.Books.Pipeline`, not generic record management.
  """

  import Ecto.Query, warn: false

  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Repo

  require Logger

  @typedoc """
  Inner reason when a chunk fails validation or the bulk insert count
  doesn't match expectations.
  """
  @type chunk_error ::
          {:invalid_chunk, keyword(), map()}
          | {:chunk_insert_count_mismatch, non_neg_integer(), non_neg_integer()}

  @typedoc """
  Error reasons returned by `persist_books_and_chunks`.

  - `{:invalid_input, map()}` — the input tuple didn't contain a
    `%ParsedBook{}` (guard clause catch-all).
  - `{String.t(), reason}` — the Ecto.Multi transaction failed; the
    string is `source_file_path` for traceability, and the reason is
    either an `Ecto.Changeset.t()` (book insert failed) or a
    `chunk_error()` (chunk validation or count mismatch).
  """
  @type persist_error ::
          {:invalid_input, map()}
          | {String.t(), Ecto.Changeset.t() | chunk_error()}

  @doc """
  Persists a `{book, chunks}` pair in one transaction, unless a book with
  the same `file_hash` already exists. Then no book or chunk is inserted,
  and the answer depends on that book: `:completed` with every chunk
  embedded under `embedding_model` is `{:duplicate, existing}`, never
  `{:ok, _}`, so a caller cannot mistake it for rows to embed; anything
  else is `{:ok, {existing, existing_chunks}}`, the rows to resume, in
  `chunk_index` order, with every vector not produced by `embedding_model`
  cleared (on the returned rows and the stored ones).
  """
  @spec persist_books_and_chunks(
          {ParsedBook.t(), [Chunk.t()]} | {term(), term()},
          String.t()
        ) ::
          {:ok, {ParsedBook.t(), [Chunk.t()]}}
          | {:duplicate, ParsedBook.t()}
          | {:error, persist_error()}
  def persist_books_and_chunks({%ParsedBook{file_hash: hash} = book, chunks}, embedding_model)
      when is_list(chunks) and is_binary(embedding_model) do
    case Repo.one(from b in ParsedBook, where: b.file_hash == ^hash) do
      nil -> insert_books_and_chunks(book, chunks)
      %ParsedBook{} = existing -> duplicate_or_resume(existing, embedding_model)
    end
  end

  def persist_books_and_chunks({book, chunks}, _embedding_model) do
    {:error, {:invalid_input, %{book: book, chunks: chunks}}}
  end

  defp duplicate_or_resume(%ParsedBook{} = existing, embedding_model) do
    chunks = existing_chunks(existing)

    if ingested_under?(existing, chunks, embedding_model) do
      Logger.debug(
        "Skipping already-ingested book #{existing.title} (#{existing.file_hash}) under #{embedding_model}"
      )

      {:duplicate, existing}
    else
      Logger.info(
        "Resuming #{existing.embedding_status} book #{existing.title} (#{existing.file_hash}) " <>
          "under #{embedding_model}: persisted by an earlier run, not finished under this model"
      )

      {:ok, {existing, clear_other_models(existing, embedding_model)}}
    end
  end

  defp ingested_under?(%ParsedBook{embedding_status: :completed}, chunks, embedding_model) do
    Enum.all?(chunks, &(&1.embedding_model == embedding_model))
  end

  defp ingested_under?(%ParsedBook{}, _chunks, _embedding_model), do: false

  # A resumed book's chunks are re-embedded under embedding_model; any vector
  # another model (or an unknown one) produced is cleared first, so a chunk
  # whose re-embed fails is left unembedded rather than holding a vector the
  # rest of the book no longer shares.
  defp clear_other_models(%ParsedBook{id: book_id} = book, embedding_model) do
    {_count, _} =
      Repo.update_all(
        from(c in Chunk,
          where: c.parsed_book_id == ^book_id,
          where: is_nil(c.embedding_model) or c.embedding_model != ^embedding_model
        ),
        set: [embedding: nil, embedding_model: nil]
      )

    existing_chunks(book)
  end

  defp existing_chunks(%ParsedBook{id: book_id}) do
    Repo.all(from c in Chunk, where: c.parsed_book_id == ^book_id, order_by: c.chunk_index)
  end

  @doc """
  Persists the pair without the `file_hash` lookup. If another run inserted
  the same bytes first, the unique index on `file_hash` refuses the insert
  and the winner's row comes back as `{:duplicate, existing}`: losing that
  check-then-insert race is a duplicate, not a persist error.
  """
  @spec insert_books_and_chunks(ParsedBook.t(), [Chunk.t()]) ::
          {:ok, {ParsedBook.t(), [Chunk.t()]}}
          | {:duplicate, ParsedBook.t()}
          | {:error, {String.t(), Ecto.Changeset.t() | chunk_error()}}
  def insert_books_and_chunks(%ParsedBook{} = book, chunks) when is_list(chunks) do
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

      {:error, :book, %Ecto.Changeset{} = changeset, _changes_so_far} ->
        duplicate_or_error(changeset, book)

      {:error, _step, reason, _changes_so_far} ->
        {:error, {book.source_file_path, reason}}
    end
  end

  # The book insert failed. If it was the unique index on file_hash, another
  # run inserted the same bytes between our lookup and our insert (or the
  # caller skipped the lookup): that is the duplicate case, answered with
  # the row that won. Any other changeset error is a genuine persist error.
  defp duplicate_or_error(changeset, book) do
    with true <- unique_file_hash_violation?(changeset),
         %ParsedBook{} = existing <-
           Repo.one(from b in ParsedBook, where: b.file_hash == ^book.file_hash) do
      {:duplicate, existing}
    else
      _no_winner_or_other_error -> {:error, {book.source_file_path, changeset}}
    end
  end

  defp unique_file_hash_violation?(%Ecto.Changeset{errors: errors}) do
    match?({_message, [constraint: :unique, constraint_name: _name]}, errors[:file_hash])
  end
end
