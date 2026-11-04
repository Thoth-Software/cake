defmodule Cake.Books.PersistencePropertyTest do
  @moduledoc """
  Property tests for `Cake.Books.Persistence.persist_books_and_chunks/2`.

  Persist-time position is the single source of truth for `chunk_index`: for
  any incoming chunk list, whatever its indices (gaps, duplicates, out of
  order), the stored chunks are numbered `0..N-1` in input order, with a
  matching row count and every other field carried through.

  The duplicate skip is model-aware (#284): for any stored status and any
  per-chunk stored models, a `file_hash` hit is `{:duplicate, _}` exactly
  when the book is `:completed` and every chunk's `embedding_model` equals
  the requested one; otherwise the book is resumed, and no resumed chunk
  carries a vector under a model other than the requested one. Example
  tests live in `persistence_test.exs`.
  """

  use Cake.DataCase, async: true
  use ExUnitProperties

  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Books.Persistence

  # Each iteration inserts a book and its chunks, so the run count is modest.
  @max_runs 40

  @model "model-a"
  @models [nil, "model-a", "model-b"]

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp book do
    gen all(title <- string(:alphanumeric, min_length: 1, max_length: 16)) do
      %ParsedBook{
        title: title,
        source_file_path: "/tmp/#{title}-#{System.unique_integer([:positive])}.pdf",
        source_format: "pdf",
        file_hash: "hash-#{System.unique_integer([:positive])}",
        file_size: 123,
        total_pages: 6,
        word_count: 3,
        parsed_at: DateTime.truncate(DateTime.utc_now(), :second),
        embedding_status: :pending
      }
    end
  end

  # Incoming chunks with arbitrary, possibly repeated indices and page numbers.
  defp chunk do
    gen all(
          chunk_index <- integer(0..50),
          page_number <- one_of([constant(nil), integer(1..50)]),
          text <- string(:alphanumeric, min_length: 1, max_length: 24)
        ) do
      %Chunk{
        text: text,
        page_number: page_number,
        chunk_index: chunk_index,
        word_count: 1,
        char_count: String.length(text)
      }
    end
  end

  defp chunks, do: list_of(chunk(), max_length: 8)

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "stored chunk_index is exactly 0..N-1 in input order, whatever the incoming indices" do
    check all(book <- book(), chunks <- chunks(), max_runs: @max_runs) do
      assert {:ok, {%ParsedBook{}, persisted}} =
               Persistence.persist_books_and_chunks({book, chunks}, @model)

      by_index = Enum.sort_by(persisted, & &1.chunk_index)

      assert Enum.map(by_index, & &1.chunk_index) == Enum.to_list(0..(length(chunks) - 1)//1)
      assert Enum.map(by_index, & &1.text) == Enum.map(chunks, & &1.text)
      assert Enum.map(by_index, & &1.page_number) == Enum.map(chunks, & &1.page_number)
    end
  end

  property "the row count matches the incoming chunk count and every row belongs to the book" do
    check all(book <- book(), chunks <- chunks(), max_runs: @max_runs) do
      {:ok, {%ParsedBook{id: book_id}, persisted}} =
        Persistence.persist_books_and_chunks({book, chunks}, @model)

      stored = Repo.all(Chunk.by_book(Chunk.base_query(), book_id))

      assert length(persisted) == length(chunks)
      assert length(stored) == length(chunks)
      assert Enum.all?(persisted, &(&1.parsed_book_id == book_id))
    end
  end

  property "a file_hash hit is a duplicate iff the book is :completed and every chunk carries the requested model" do
    check all(
            book <- book(),
            status <- member_of([:pending, :processing, :completed, :failed]),
            stored_models <- list_of(member_of(@models), min_length: 1, max_length: 6),
            requested <- member_of(["model-a", "model-b"]),
            max_runs: @max_runs
          ) do
      incoming = Enum.map(Enum.with_index(stored_models), fn {_model, i} -> plain_chunk(i) end)

      {:ok, {first_book, first_chunks}} =
        Persistence.persist_books_and_chunks({book, incoming}, requested)

      first_chunks
      |> Enum.zip(stored_models)
      |> Enum.each(fn {%{id: id}, model} ->
        embedding = if model, do: [0.1, 0.2, 0.3]

        {:ok, _} =
          Cake.Books.update_chunk(Repo.get!(Chunk, id), %{
            embedding: embedding,
            embedding_model: model
          })
      end)

      {:ok, _} = Cake.Books.update_parsed_book(first_book, %{embedding_status: status})

      dupe = %ParsedBook{
        book
        | source_file_path: "/tmp/dupe-#{System.unique_integer([:positive])}.pdf"
      }

      expect_duplicate? = status == :completed and Enum.all?(stored_models, &(&1 == requested))

      case Persistence.persist_books_and_chunks({dupe, incoming}, requested) do
        {:duplicate, %ParsedBook{id: id}} ->
          assert expect_duplicate?
          assert id == first_book.id

        {:ok, {%ParsedBook{id: id}, resumed}} ->
          refute expect_duplicate?
          assert id == first_book.id
          assert length(resumed) == length(stored_models)
          assert Enum.all?(resumed, &(&1.embedding_model in [nil, requested]))
          assert Enum.all?(resumed, &(is_nil(&1.embedding_model) == is_nil(&1.embedding)))
      end
    end
  end

  defp plain_chunk(i) do
    %Chunk{text: "chunk #{i}", chunk_index: i, word_count: 2, char_count: 7}
  end
end
