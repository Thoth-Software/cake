defmodule Cake.Books.PersistenceTest do
  @moduledoc """
  Pins the write-path invariant that `chunk_index` is dense and contiguous in
  stored order. Persistence is the single source of truth for ordering, so even
  if upstream parsing leaves gaps (a blank page rejected after indexing), the
  persisted chunks must be numbered 0..N-1 with no holes — `expand_with_neighbors`
  and `within_pages` rely on contiguity.
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

  test "stored order matches the incoming chunk order" do
    chunks = [chunk(0, 1), chunk(2, 3), chunk(5, 6)]

    {:ok, {_book, persisted_chunks}} = Persistence.persist_books_and_chunks({book(), chunks})

    by_index = Enum.sort_by(persisted_chunks, & &1.chunk_index)
    assert Enum.map(by_index, & &1.page_number) == [1, 3, 6]
  end
end
