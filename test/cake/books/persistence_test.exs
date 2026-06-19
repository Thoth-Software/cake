defmodule Cake.Books.PersistenceTest do
  @moduledoc """
  Write-path coverage for `Cake.Books.Persistence`, focused on the chunk_index
  contract (#168).

  Persistence is the single source of truth for `chunk_index`: it assigns
  contiguous indices at persist time, regardless of any index the parse step
  put on the input chunks. Contiguity is what `expand_with_neighbors`/
  `within_pages` rely on, so gaps (from blank-chunk rejection upstream) must
  not survive into the database.
  """

  use Cake.DataCase, async: true

  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Books.Persistence

  defp book(attrs \\ %{}) do
    Map.merge(
      %ParsedBook{
        title: "T",
        source_file_path: "/tmp/x.pdf",
        source_format: "pdf",
        file_hash: "hash-#{System.unique_integer([:positive])}",
        file_size: 10,
        total_pages: 3,
        word_count: 9,
        parsed_at: DateTime.truncate(DateTime.utc_now(), :second),
        embedding_status: :pending
      },
      attrs
    )
  end

  defp chunk(text, overrides \\ %{}) do
    Map.merge(
      %Chunk{text: text, word_count: 1, char_count: String.length(text), page_number: 1},
      overrides
    )
  end

  describe "persist_books_and_chunks/1 chunk_index" do
    test "assigns contiguous indices, overriding any indices on the input chunks" do
      chunks = [
        chunk("a", %{chunk_index: 5}),
        chunk("b", %{chunk_index: 3}),
        chunk("c", %{chunk_index: 9})
      ]

      assert {:ok, {_book, persisted}} = Persistence.persist_books_and_chunks({book(), chunks})

      assert persisted |> Enum.map(& &1.chunk_index) |> Enum.sort() == [0, 1, 2]
    end

    test "assigns indices even when the input chunks carry none" do
      chunks = [chunk("a"), chunk("b")]

      assert {:ok, {_book, persisted}} = Persistence.persist_books_and_chunks({book(), chunks})

      assert persisted |> Enum.map(& &1.chunk_index) |> Enum.sort() == [0, 1]
    end
  end
end
