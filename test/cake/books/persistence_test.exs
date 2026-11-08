defmodule Cake.Books.PersistenceTest do
  @moduledoc """
  Pins the write-path invariant that `chunk_index` is dense and contiguous in
  stored order. Persistence is the single source of truth for ordering, so even
  if upstream parsing leaves gaps (a blank page rejected after indexing), the
  persisted chunks must be numbered 0..N-1 with no holes — `expand_with_neighbors`
  and `within_pages` rely on contiguity. `persistence_property_test.exs` pins
  the densification for arbitrary incoming indices; the example here is the
  readable anchor.

  It also pins the model-aware duplicate skip (#284): a `file_hash` hit on a
  `:completed` book is a duplicate only when every one of its chunks was
  embedded under the model the caller is ingesting with. Any other stored
  model, `nil` included (rows embedded before the column existed, or never
  embedded), makes the book one to resume, and resuming clears the vectors
  that do not belong to the requested model so no chunk keeps a stale one.
  """
  use Cake.DataCase, async: true

  import Ecto.Query

  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Books.Persistence

  @model "model-a"
  @other_model "model-b"

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

  # Stands in for a finished run: every chunk embedded under `model`, the
  # book :completed.
  defp complete_under!(%ParsedBook{id: book_id} = book, model) do
    embed_chunks_under!(book_id, model)
    {:ok, completed} = Cake.Books.update_parsed_book(book, %{embedding_status: :completed})
    completed
  end

  defp embed_chunks_under!(book_id, model, where \\ fn _chunk -> true end) do
    Chunk
    |> where([c], c.parsed_book_id == ^book_id)
    |> Repo.all()
    |> Enum.filter(where)
    |> Enum.each(fn chunk ->
      {:ok, _} =
        Cake.Books.update_chunk(chunk, %{embedding: [0.1, 0.2, 0.3], embedding_model: model})
    end)
  end

  defp stored_chunks(book_id) do
    Repo.all(from c in Chunk, where: c.parsed_book_id == ^book_id, order_by: c.chunk_index)
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
             Persistence.persist_books_and_chunks({book(), chunks}, @model)

    indices = persisted_chunks |> Enum.map(& &1.chunk_index) |> Enum.sort()
    assert indices == [0, 1, 2]
  end

  test "returns {:error, :invalid_input, _} for non-ParsedBook inputs" do
    assert {:error, {:invalid_input, _}} =
             Persistence.persist_books_and_chunks({"not_a_book", []}, @model)
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

    {:ok, {first_book, first_chunks}} = Persistence.persist_books_and_chunks({b, chunks}, @model)
    complete_under!(first_book, @model)

    dupe = %ParsedBook{b | source_file_path: "/tmp/different.pdf", file_hash: b.file_hash}

    assert {:duplicate, %ParsedBook{} = existing} =
             Persistence.persist_books_and_chunks({dupe, chunks}, @model)

    assert existing.id == first_book.id
    assert existing.source_file_path == first_book.source_file_path
    assert existing.embedding_status == :completed
    assert length(Repo.all(ParsedBook)) == 1
    assert Enum.map(Repo.all(Chunk), & &1.id) == Enum.map(first_chunks, & &1.id)
  end

  test "a :processing book with the same file_hash is resumed: nothing proves another run still owns it" do
    b = book()

    {:ok, {first_book, first_chunks}} =
      Persistence.persist_books_and_chunks({b, [chunk(0, 1)]}, @model)

    {:ok, _processing} =
      Cake.Books.update_parsed_book(first_book, %{embedding_status: :processing})

    dupe = %ParsedBook{b | source_file_path: "/tmp/different.pdf"}

    assert {:ok, {%ParsedBook{id: id}, resumed}} =
             Persistence.persist_books_and_chunks({dupe, [chunk(0, 1)]}, @model)

    assert id == first_book.id
    assert Enum.map(resumed, & &1.id) == Enum.map(first_chunks, & &1.id)
    assert length(Repo.all(ParsedBook)) == 1
  end

  test "a :failed book with the same file_hash is resumed: the existing rows come back as {:ok, _}" do
    b = book()
    chunks = [chunk(0, 1), chunk(1, 2)]

    {:ok, {first_book, first_chunks}} = Persistence.persist_books_and_chunks({b, chunks}, @model)
    {:ok, _failed} = Cake.Books.update_parsed_book(first_book, %{embedding_status: :failed})

    dupe = %ParsedBook{b | source_file_path: "/tmp/different.pdf"}

    assert {:ok, {%ParsedBook{} = existing, resumed}} =
             Persistence.persist_books_and_chunks({dupe, chunks}, @model)

    assert existing.id == first_book.id
    assert existing.source_file_path == first_book.source_file_path
    assert Enum.map(resumed, & &1.id) == Enum.map(first_chunks, & &1.id)
    assert Enum.map(resumed, & &1.chunk_index) == [0, 1]
    assert length(Repo.all(ParsedBook)) == 1
    assert length(Repo.all(Chunk)) == 2
  end

  test "a :pending book with the same file_hash is resumed as well" do
    b = book()

    {:ok, {first_book, _chunks}} =
      Persistence.persist_books_and_chunks({b, [chunk(0, 1)]}, @model)

    assert first_book.embedding_status == :pending

    dupe = %ParsedBook{b | source_file_path: "/tmp/different.pdf"}

    assert {:ok, {%ParsedBook{id: id}, [%Chunk{}]}} =
             Persistence.persist_books_and_chunks({dupe, [chunk(0, 1)]}, @model)

    assert id == first_book.id
    assert length(Repo.all(ParsedBook)) == 1
  end

  # Two runs of the same bytes can both find no row and both insert; the
  # unique index refuses the second. insert_books_and_chunks/3 skips the
  # lookup, which is exactly the loser's position, so it reproduces the race
  # deterministically. The loser cannot know which model the in-flight winner
  # is embedding under (its chunks carry none yet), so it answers a duplicate
  # only when the winner is already :completed under the requested model, and
  # otherwise a persist error naming the winner: recorded as a books.persist
  # failure, which the sweep retries through the model-aware lookup (#284).
  describe "losing a check-then-insert race on file_hash" do
    test "to a winner still in flight is a {:concurrent_ingest, winner_id} persist error, never a silent duplicate" do
      b = book()
      chunks = [chunk(0, 1)]

      {:ok, {winner, _chunks}} = Persistence.persist_books_and_chunks({b, chunks}, @model)
      loser = %ParsedBook{b | source_file_path: "/tmp/racer.pdf"}

      assert {:error, {"/tmp/racer.pdf", {:concurrent_ingest, winner_id}}} =
               Persistence.insert_books_and_chunks(loser, chunks, @model)

      assert winner_id == winner.id
      assert length(Repo.all(ParsedBook)) == 1
      assert length(Repo.all(Chunk)) == 1
    end

    test "to a winner :completed under the requested model is a duplicate" do
      b = book()
      chunks = [chunk(0, 1)]

      {:ok, {winner, _chunks}} = Persistence.persist_books_and_chunks({b, chunks}, @model)
      complete_under!(winner, @model)
      loser = %ParsedBook{b | source_file_path: "/tmp/racer.pdf"}

      assert {:duplicate, %ParsedBook{id: id}} =
               Persistence.insert_books_and_chunks(loser, chunks, @model)

      assert id == winner.id
    end

    test "to a winner :completed under another model is a {:concurrent_ingest, winner_id} persist error" do
      b = book()
      chunks = [chunk(0, 1)]

      {:ok, {winner, _chunks}} = Persistence.persist_books_and_chunks({b, chunks}, @other_model)
      complete_under!(winner, @other_model)
      loser = %ParsedBook{b | source_file_path: "/tmp/racer.pdf"}

      assert {:error, {"/tmp/racer.pdf", {:concurrent_ingest, winner_id}}} =
               Persistence.insert_books_and_chunks(loser, chunks, @model)

      assert winner_id == winner.id
    end
  end

  test "returns error for chunks missing required fields" do
    bad_chunk = %Chunk{text: nil, chunk_index: nil, word_count: nil, char_count: nil}

    assert {:error, _} = Persistence.persist_books_and_chunks({book(), [bad_chunk]}, @model)
  end

  describe "the duplicate skip is model-aware (#284)" do
    test "a :completed book whose every chunk carries the requested model is a duplicate" do
      b = book()

      {:ok, {first_book, _}} =
        Persistence.persist_books_and_chunks({b, [chunk(0, 1), chunk(1, 2)]}, @model)

      complete_under!(first_book, @model)

      dupe = %ParsedBook{b | source_file_path: "/tmp/different.pdf"}

      assert {:duplicate, %ParsedBook{id: id}} =
               Persistence.persist_books_and_chunks({dupe, [chunk(0, 1), chunk(1, 2)]}, @model)

      assert id == first_book.id
    end

    test "a :completed book embedded under another model is resumed, not dropped" do
      b = book()

      {:ok, {first_book, first_chunks}} =
        Persistence.persist_books_and_chunks({b, [chunk(0, 1), chunk(1, 2)]}, @other_model)

      complete_under!(first_book, @other_model)

      dupe = %ParsedBook{b | source_file_path: "/tmp/different.pdf"}

      assert {:ok, {%ParsedBook{id: id}, resumed}} =
               Persistence.persist_books_and_chunks({dupe, [chunk(0, 1), chunk(1, 2)]}, @model)

      assert id == first_book.id
      assert Enum.map(resumed, & &1.id) == Enum.map(first_chunks, & &1.id)
      assert length(Repo.all(ParsedBook)) == 1
      assert length(Repo.all(Chunk)) == 2
    end

    test "resuming under another model clears the other model's vectors, in the returned rows and the stored ones" do
      # Without this, a chunk whose re-embed fails keeps the old model's
      # vector beside its siblings' new ones: the very mix #284 forbids.
      b = book()

      {:ok, {first_book, _}} =
        Persistence.persist_books_and_chunks({b, [chunk(0, 1), chunk(1, 2)]}, @other_model)

      complete_under!(first_book, @other_model)

      dupe = %ParsedBook{b | source_file_path: "/tmp/different.pdf"}

      assert {:ok, {_book, resumed}} =
               Persistence.persist_books_and_chunks({dupe, [chunk(0, 1), chunk(1, 2)]}, @model)

      for chunks <- [resumed, stored_chunks(first_book.id)] do
        assert Enum.map(chunks, & &1.embedding) == [nil, nil]
        assert Enum.map(chunks, & &1.embedding_model) == [nil, nil]
      end
    end

    test "resuming keeps the vectors already embedded under the requested model" do
      # A :failed book: chunk 0 embedded under the requested model, chunk 1
      # never embedded. Chunk 0's vector is the right one and stays.
      b = book()

      {:ok, {first_book, _}} =
        Persistence.persist_books_and_chunks({b, [chunk(0, 1), chunk(1, 2)]}, @model)

      embed_chunks_under!(first_book.id, @model, &(&1.chunk_index == 0))
      {:ok, _} = Cake.Books.update_parsed_book(first_book, %{embedding_status: :failed})

      dupe = %ParsedBook{b | source_file_path: "/tmp/different.pdf"}

      assert {:ok, {_book, [kept, never_embedded]}} =
               Persistence.persist_books_and_chunks({dupe, [chunk(0, 1), chunk(1, 2)]}, @model)

      assert {kept.embedding, kept.embedding_model} == {[0.1, 0.2, 0.3], @model}
      assert {never_embedded.embedding, never_embedded.embedding_model} == {nil, nil}
    end

    test "a :completed book with a chunk of unknown model (nil, pre-#284) is resumed" do
      # Historical rows load embedding_model nil: nothing says they were
      # embedded under the requested model, so they are not a duplicate of it.
      b = book()

      {:ok, {first_book, _}} =
        Persistence.persist_books_and_chunks({b, [chunk(0, 1), chunk(1, 2)]}, @model)

      embed_chunks_under!(first_book.id, @model, &(&1.chunk_index == 0))
      embed_chunks_under!(first_book.id, nil, &(&1.chunk_index == 1))
      {:ok, _} = Cake.Books.update_parsed_book(first_book, %{embedding_status: :completed})

      dupe = %ParsedBook{b | source_file_path: "/tmp/different.pdf"}

      assert {:ok, {%ParsedBook{}, [_, _]}} =
               Persistence.persist_books_and_chunks({dupe, [chunk(0, 1), chunk(1, 2)]}, @model)
    end
  end
end
