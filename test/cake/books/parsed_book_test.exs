defmodule Cake.Books.ParsedBookTest do
  use Cake.DataCase

  import Cake.BooksFixtures

  alias Cake.Books
  alias Cake.Books.ParsedBook

  describe "Cake.GDS contract" do
    test "declares @behaviour Cake.GDS" do
      behaviours = ParsedBook.__info__(:attributes)[:behaviour] || []
      assert Cake.GDS in behaviours
    end

    test "index_name/0 returns the chunks_of_books index name" do
      assert ParsedBook.index_name() == "chunks_of_books"
    end

    test "search_fields/0 returns section_title (boost 2) and text" do
      assert ParsedBook.search_fields() == ["section_title^2", "text"]
    end

    test "load_from_hits/1 hydrates chunks from hit IDs in the same order as the hits" do
      book = parsed_book_fixture()

      {:ok, chunk_a} =
        Books.create_chunk(%{
          parsed_book_id: book.id,
          text: "alpha",
          chunk_index: 0,
          word_count: 1,
          char_count: 5
        })

      {:ok, chunk_b} =
        Books.create_chunk(%{
          parsed_book_id: book.id,
          text: "beta",
          chunk_index: 1,
          word_count: 1,
          char_count: 4
        })

      hits = [
        %Snap.Hit{source: %{"id" => chunk_b.id}},
        %Snap.Hit{source: %{"id" => chunk_a.id}}
      ]

      loaded = ParsedBook.load_from_hits(hits)

      assert Enum.map(loaded, & &1.id) == [chunk_b.id, chunk_a.id]
    end

    test "expand_with_neighbors/2 returns chunks within offset window" do
      book = parsed_book_fixture()

      chunks =
        for idx <- 0..4 do
          {:ok, chunk} =
            Books.create_chunk(%{
              parsed_book_id: book.id,
              text: "chunk #{idx}",
              chunk_index: idx,
              word_count: 2,
              char_count: 7
            })

          chunk
        end

      center = Enum.at(chunks, 2)
      expanded = ParsedBook.expand_with_neighbors([center], 1)

      assert Enum.sort(Enum.map(expanded, & &1.chunk_index)) == [1, 2, 3]
    end

    test "expand_with_neighbors/2 does not return negative-index chunks at the low boundary" do
      book = parsed_book_fixture()

      chunks =
        for idx <- 0..4 do
          {:ok, chunk} =
            Books.create_chunk(%{
              parsed_book_id: book.id,
              text: "chunk #{idx}",
              chunk_index: idx,
              word_count: 2,
              char_count: 7
            })

          chunk
        end

      first = Enum.at(chunks, 0)
      expanded = ParsedBook.expand_with_neighbors([first], 2)

      assert Enum.sort(Enum.map(expanded, & &1.chunk_index)) == [0, 1, 2]
    end
  end
end
