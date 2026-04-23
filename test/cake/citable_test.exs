defmodule Cake.CitableTest do
  use Cake.DataCase

  alias Cake.Books.Chunk
  alias Cake.Citable

  describe "Cake.Books.Chunk implementation" do
    import Cake.BooksFixtures

    setup do
      raw =
        chunk_fixture(%{
          page_number: 42,
          section_title: "Introduction",
          chunk_index: 3,
          text: "Chapter one begins with a simple observation about the nature of collections."
        })

      %{chunk: Repo.preload(raw, :parsed_book)}
    end

    test "returns a map with exactly the five required keys", %{chunk: chunk} do
      keys = chunk |> Citable.metadata() |> Map.keys() |> Enum.sort()
      assert keys == [:extras, :id, :label, :preview, :source_ref]
    end

    test "id is the chunk's UUID", %{chunk: chunk} do
      assert Citable.metadata(chunk).id == chunk.id
    end

    test "preview is the first 200 characters when text is longer than 200 chars" do
      long_text = String.duplicate("a", 350)
      chunk = Repo.preload(chunk_fixture(%{text: long_text}), :parsed_book)
      preview = Citable.metadata(chunk).preview

      assert String.length(preview) == 200
      assert preview == String.slice(chunk.text, 0, 200)
    end

    test "preview is the full text when text is shorter than 200 chars" do
      chunk = Repo.preload(chunk_fixture(%{text: "short text"}), :parsed_book)

      assert Citable.metadata(chunk).preview == "short text"
    end

    test "source_ref is the parsed_book's source_file_path", %{chunk: chunk} do
      assert Citable.metadata(chunk).source_ref == chunk.parsed_book.source_file_path
    end

    test "extras contains book_title, page_number, section_title, chunk_index", %{chunk: chunk} do
      extras = Citable.metadata(chunk).extras

      assert Enum.sort(Map.keys(extras)) ==
               [:book_title, :chunk_index, :page_number, :section_title]

      assert extras.book_title == chunk.parsed_book.title
      assert extras.page_number == chunk.page_number
      assert extras.section_title == chunk.section_title
      assert extras.chunk_index == chunk.chunk_index
    end

    test "label is just the title when page and section are both nil" do
      chunk =
        Repo.preload(
          chunk_fixture(%{page_number: nil, section_title: nil}),
          :parsed_book
        )

      assert Citable.metadata(chunk).label == chunk.parsed_book.title
    end

    test "label includes page when only page is present" do
      chunk =
        Repo.preload(
          chunk_fixture(%{page_number: 17, section_title: nil}),
          :parsed_book
        )

      assert Citable.metadata(chunk).label == "#{chunk.parsed_book.title}, p. 17"
    end

    test "label includes section when only section is present" do
      chunk =
        Repo.preload(
          chunk_fixture(%{page_number: nil, section_title: "Preface"}),
          :parsed_book
        )

      assert Citable.metadata(chunk).label == "#{chunk.parsed_book.title} — Preface"
    end

    test "label includes both page and section when both are present" do
      chunk =
        Repo.preload(
          chunk_fixture(%{page_number: 99, section_title: "Appendix A"}),
          :parsed_book
        )

      assert Citable.metadata(chunk).label ==
               "#{chunk.parsed_book.title}, p. 99 — Appendix A"
    end

    test "raises FunctionClauseError when parsed_book is not preloaded" do
      chunk = %Chunk{
        id: Ecto.UUID.generate(),
        text: "hi",
        chunk_index: 0,
        parsed_book: %Ecto.Association.NotLoaded{
          __field__: :parsed_book,
          __owner__: Chunk,
          __cardinality__: :one
        }
      }

      assert_raise FunctionClauseError, fn -> Citable.metadata(chunk) end
    end
  end
end
