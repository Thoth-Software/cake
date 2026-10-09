defmodule Cake.Books.PersistenceTest do
  @moduledoc """
  Pins the write-path invariant that `chunk_index` is dense and contiguous in
  stored order. Persistence is the single source of truth for ordering, so even
  if upstream parsing leaves gaps (a blank page rejected after indexing), the
  persisted chunks must be numbered 0..N-1 with no holes — `expand_with_neighbors`
  and `within_pages` rely on contiguity. `persistence_property_test.exs` pins
  the densification for arbitrary incoming indices; the example here is the
  readable anchor.
  """
  use Cake.DataCase, async: true

  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Books.Persistence

  defp book do
    %ParsedBook{
      title: "Test Book",
      source_file_path: "/tmp/test-#{System.unique_integer([:positive])}.pdf",
      source_format: "pdf",
      file_hash: "hash-#{System.unique_integer([:positive])}",
      file_size: 123,
      total_pages: 6,
      word_count: 3,
      parsed_at: DateTime.truncate(DateTime.utc_now(), :second),
      embedding_status: :pending
    }
  end

  defp chunk(chunk_index, page_number) do
    %Chunk{
      text: "chunk text #{chunk_index}",
      page_number: page_number,
      chunk_index: chunk_index,
      word_count: 2,
      char_count: 11
    }
  end

  test "densifies chunk_index even when incoming chunks have gaps" do
    # Simulate the PDF path where pages 1 and 3 were blank and rejected after
    # indexing, leaving gappy indices [0, 2, 5].
    chunks = [chunk(0, 1), chunk(2, 3), chunk(5, 6)]

    assert {:ok, {_persisted_book, persisted_chunks}} =
             Persistence.persist_books_and_chunks({book(), chunks})

    indices = persisted_chunks |> Enum.map(& &1.chunk_index) |> Enum.sort()
    assert indices == [0, 1, 2]
  end

  test "returns {:error, :invalid_input, _} for non-ParsedBook inputs" do
    assert {:error, {:invalid_input, _}} =
             Persistence.persist_books_and_chunks({"not_a_book", []})
  end

  # A file_hash hit means the bytes are known; whether the book is *done*
  # is its embedding_status, and :completed is the only done state — it is
  # written after every chunk is embedded and accepted by the index. Any
  # other status (:pending, :processing with no owner to speak of, :failed)
  # is a book an earlier run did not finish, handed back with its chunks so
  # the pipeline resumes it.
  test "reports a duplicate file_hash of a :completed book as {:duplicate, existing} and writes nothing" do
    b = book()
    chunks = [chunk(0, 1)]

    {:ok, {first_book, first_chunks}} = Persistence.persist_books_and_chunks({b, chunks})
    {:ok, _completed} = Cake.Books.update_parsed_book(first_book, %{embedding_status: :completed})

    dupe = %ParsedBook{b | source_file_path: "/tmp/different.pdf", file_hash: b.file_hash}

    assert {:duplicate, %ParsedBook{} = existing} =
             Persistence.persist_books_and_chunks({dupe, chunks})

    assert existing.id == first_book.id
    assert existing.source_file_path == first_book.source_file_path
    assert existing.embedding_status == :completed
    assert length(Repo.all(ParsedBook)) == 1
    assert Enum.map(Repo.all(Chunk), & &1.id) == Enum.map(first_chunks, & &1.id)
  end

  test "a :processing book with the same file_hash is resumed: nothing proves another run still owns it" do
    b = book()
    {:ok, {first_book, first_chunks}} = Persistence.persist_books_and_chunks({b, [chunk(0, 1)]})

    {:ok, _processing} =
      Cake.Books.update_parsed_book(first_book, %{embedding_status: :processing})

    dupe = %ParsedBook{b | source_file_path: "/tmp/different.pdf"}

    assert {:ok, {%ParsedBook{id: id}, resumed}} =
             Persistence.persist_books_and_chunks({dupe, [chunk(0, 1)]})

    assert id == first_book.id
    assert Enum.map(resumed, & &1.id) == Enum.map(first_chunks, & &1.id)
    assert length(Repo.all(ParsedBook)) == 1
  end

  test "a :failed book with the same file_hash is resumed: the existing rows come back as {:ok, _}" do
    b = book()
    chunks = [chunk(0, 1), chunk(1, 2)]

    {:ok, {first_book, first_chunks}} = Persistence.persist_books_and_chunks({b, chunks})
    {:ok, _failed} = Cake.Books.update_parsed_book(first_book, %{embedding_status: :failed})

    dupe = %ParsedBook{b | source_file_path: "/tmp/different.pdf"}

    assert {:ok, {%ParsedBook{} = existing, resumed}} =
             Persistence.persist_books_and_chunks({dupe, chunks})

    assert existing.id == first_book.id
    assert existing.source_file_path == first_book.source_file_path
    assert Enum.map(resumed, & &1.id) == Enum.map(first_chunks, & &1.id)
    assert Enum.map(resumed, & &1.chunk_index) == [0, 1]
    assert length(Repo.all(ParsedBook)) == 1
    assert length(Repo.all(Chunk)) == 2
  end

  test "a :pending book with the same file_hash is resumed as well" do
    b = book()
    {:ok, {first_book, _chunks}} = Persistence.persist_books_and_chunks({b, [chunk(0, 1)]})
    assert first_book.embedding_status == :pending

    dupe = %ParsedBook{b | source_file_path: "/tmp/different.pdf"}

    assert {:ok, {%ParsedBook{id: id}, [%Chunk{}]}} =
             Persistence.persist_books_and_chunks({dupe, [chunk(0, 1)]})

    assert id == first_book.id
    assert length(Repo.all(ParsedBook)) == 1
  end

  test "losing a check-then-insert race on file_hash is a duplicate, not a failure" do
    # Two runs of the same bytes can both find no row and both insert; the
    # unique index refuses the second. persist_books_and_chunks/2 skips the
    # lookup, which is exactly the loser's position, so it reproduces the
    # race deterministically: the answer must be the winner's row, as
    # {:duplicate, existing}, never a persist error.
    b = book()
    chunks = [chunk(0, 1)]

    {:ok, {winner, _chunks}} = Persistence.persist_books_and_chunks({b, chunks})

    loser = %ParsedBook{b | source_file_path: "/tmp/racer.pdf"}

    assert {:duplicate, %ParsedBook{} = existing} =
             Persistence.persist_books_and_chunks(loser, chunks)

    assert existing.id == winner.id
    assert length(Repo.all(ParsedBook)) == 1
  end

  test "returns error for chunks missing required fields" do
    bad_chunk = %Chunk{text: nil, chunk_index: nil, word_count: nil, char_count: nil}

    assert {:error, _} = Persistence.persist_books_and_chunks({book(), [bad_chunk]})
  end
end
