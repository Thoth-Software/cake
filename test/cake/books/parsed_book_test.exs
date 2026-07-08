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

  describe "changeset/2" do
    test "valid with all required fields" do
      attrs = %{
        source_file_path: "/tmp/test.pdf",
        source_format: "pdf",
        file_hash: "abc123",
        file_size: 100,
        title: "Test",
        word_count: 50,
        parsed_at: ~U[2025-01-01 00:00:00Z],
        embedding_status: :pending
      }

      cs = ParsedBook.changeset(%ParsedBook{}, attrs)
      assert cs.valid?
    end

    test "invalid when required fields are missing" do
      cs = ParsedBook.changeset(%ParsedBook{}, %{})
      refute cs.valid?

      errors = Cake.DataCase.errors_on(cs)
      assert errors[:source_file_path]
      assert errors[:source_format]
      assert errors[:file_hash]
      assert errors[:file_size]
      assert errors[:title]
      assert errors[:word_count]
      assert errors[:parsed_at]

      refute errors[:embedding_status],
             "embedding_status has a default and should not be required"
    end

    test "sanitizes NUL bytes in string fields" do
      attrs = %{
        source_file_path: "/tmp/test.pdf",
        source_format: "pdf",
        file_hash: "abc123",
        file_size: 100,
        title: "Test\0Book",
        word_count: 50,
        parsed_at: ~U[2025-01-01 00:00:00Z],
        embedding_status: :pending
      }

      cs = ParsedBook.changeset(%ParsedBook{}, attrs)
      assert Ecto.Changeset.get_change(cs, :title) == "TestBook"
    end
  end

  describe "query composables" do
    setup do
      book =
        parsed_book_fixture(%{
          title: "Elixir in Action",
          language: "en",
          source_file_path: "/books/elixir.pdf",
          source_format: "pdf",
          authors: ["Sasa Juric"],
          isbn: "978-1617295027",
          publisher: "Manning",
          publication_date: ~D[2019-01-15],
          parsed_at: ~U[2025-06-01 12:00:00Z]
        })

      %{book: book}
    end

    test "base_query/0 returns a queryable for parsed_books" do
      query = ParsedBook.base_query()
      assert %Ecto.Query{} = query
    end

    test "by_title/2 filters by exact title", %{book: book} do
      results = ParsedBook.base_query() |> ParsedBook.by_title("Elixir in Action") |> Repo.all()
      assert [found] = results
      assert found.id == book.id
    end

    test "by_title/2 returns empty for non-matching title" do
      results = ParsedBook.base_query() |> ParsedBook.by_title("No Such Book") |> Repo.all()
      assert results == []
    end

    test "by_language/2 filters by language", %{book: book} do
      results = ParsedBook.base_query() |> ParsedBook.by_language("en") |> Repo.all()
      assert Enum.any?(results, &(&1.id == book.id))
    end

    test "by_file_path/2 filters by source_file_path", %{book: book} do
      results =
        ParsedBook.base_query() |> ParsedBook.by_file_path("/books/elixir.pdf") |> Repo.all()

      assert [found] = results
      assert found.id == book.id
    end

    test "by_author/2 filters by a member of the authors array", %{book: book} do
      results = ParsedBook.base_query() |> ParsedBook.by_author("Sasa Juric") |> Repo.all()
      assert [found] = results
      assert found.id == book.id
    end

    test "by_author/2 returns empty for non-matching author" do
      results = ParsedBook.base_query() |> ParsedBook.by_author("Nobody") |> Repo.all()
      assert results == []
    end

    test "by_format/2 filters by source_format", %{book: book} do
      results = ParsedBook.base_query() |> ParsedBook.by_format("pdf") |> Repo.all()
      assert Enum.any?(results, &(&1.id == book.id))
    end

    test "by_isbn/2 filters by isbn", %{book: book} do
      results = ParsedBook.base_query() |> ParsedBook.by_isbn("978-1617295027") |> Repo.all()
      assert [found] = results
      assert found.id == book.id
    end

    test "by_publisher/2 filters by publisher", %{book: book} do
      results = ParsedBook.base_query() |> ParsedBook.by_publisher("Manning") |> Repo.all()
      assert [found] = results
      assert found.id == book.id
    end

    test "published_on/2 filters by exact publication_date", %{book: book} do
      results = ParsedBook.base_query() |> ParsedBook.published_on(~D[2019-01-15]) |> Repo.all()
      assert [found] = results
      assert found.id == book.id
    end

    test "published_before/2 filters books published before the given date", %{book: book} do
      results =
        ParsedBook.base_query() |> ParsedBook.published_before(~D[2020-01-01]) |> Repo.all()

      assert Enum.any?(results, &(&1.id == book.id))
    end

    test "published_before/2 excludes books published after the given date", %{book: book} do
      results =
        ParsedBook.base_query() |> ParsedBook.published_before(~D[2018-01-01]) |> Repo.all()

      refute Enum.any?(results, &(&1.id == book.id))
    end

    test "published_after/2 filters books published after the given date", %{book: book} do
      results =
        ParsedBook.base_query() |> ParsedBook.published_after(~D[2018-01-01]) |> Repo.all()

      assert Enum.any?(results, &(&1.id == book.id))
    end

    test "parsed_on/2 filters by exact parsed_at", %{book: book} do
      results =
        ParsedBook.base_query()
        |> ParsedBook.parsed_on(~U[2025-06-01 12:00:00Z])
        |> Repo.all()

      assert [found] = results
      assert found.id == book.id
    end

    test "parsed_before/2 filters books parsed before the given datetime", %{book: book} do
      results =
        ParsedBook.base_query()
        |> ParsedBook.parsed_before(~U[2026-01-01 00:00:00Z])
        |> Repo.all()

      assert Enum.any?(results, &(&1.id == book.id))
    end

    test "parsed_after/2 filters books parsed after the given datetime", %{book: book} do
      results =
        ParsedBook.base_query()
        |> ParsedBook.parsed_after(~U[2025-01-01 00:00:00Z])
        |> Repo.all()

      assert Enum.any?(results, &(&1.id == book.id))
    end

    test "queries compose: by_format + by_language", %{book: book} do
      results =
        ParsedBook.base_query()
        |> ParsedBook.by_format("pdf")
        |> ParsedBook.by_language("en")
        |> Repo.all()

      assert Enum.any?(results, &(&1.id == book.id))
    end
  end
end
