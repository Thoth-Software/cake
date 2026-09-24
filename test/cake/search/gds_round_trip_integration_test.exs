defmodule Cake.Search.GDSRoundTripIntegrationTest do
  @moduledoc """
  The GDS retrieval chain against a real node and real Postgres rows
  (#245): `Cake.Pipelines.add_to_search_backend/3` indexes embedded
  records, a search returns hits, the GDS's `load_from_hits/1` hydrates
  them in hit order, and `expand_with_neighbors/2` widens the window from
  Postgres. Every step is called directly with the test's own collection,
  so the tests stay async and never touch the GDS's fixed collection name.

  Embeddings are `unit_vector/1`s from the case template, so cosine
  ranking is exact. Runs with `mix test --only integration`.
  """

  use Cake.SearchIntegrationCase, async: true

  import Cake.BooksFixtures
  import Cake.ParsedDocumentFixtures

  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Documents.ParsedDocument
  alias Cake.FailedIngests.FailedIngest
  alias Cake.Pipelines
  alias Cake.Repo
  alias Cake.Search.Backend.OpenSearch
  alias Cake.Search.Hit
  alias Cake.Search.Query

  defp ctx, do: Pipelines.build_context(Cake.Books.Pipeline, Cake.Books.Pdf.Pipeline, "it")

  defp index_all!(records, collection) do
    indexed = records |> Pipelines.add_to_search_backend(collection, ctx()) |> Enum.to_list()
    refresh!(collection)
    indexed
  end

  defp search!(query) do
    {:ok, hits} = OpenSearch.search(query)
    hits
  end

  defp ids(structs_or_hits), do: Enum.map(structs_or_hits, & &1.id)

  describe "Books GDS (ParsedBook + Chunk)" do
    setup %{collection: collection} do
      :ok = OpenSearch.create_collection(collection, OpenSearch.build_mapping(Chunk))

      # Five ordered chunks; chunk i embeds on axis i. "needle" is in 1 and 3.
      {book, chunks} =
        book_with_chunks_fixture([
          %{text: "prologue common words", embedding: unit_vector(0)},
          %{text: "chapter one needle needle common words", embedding: unit_vector(1)},
          %{text: "chapter two common words", embedding: unit_vector(2)},
          %{text: "chapter three needle common words", embedding: unit_vector(3)},
          %{text: "epilogue common words", embedding: unit_vector(4)}
        ])

      %{book: book, chunks: chunks}
    end

    test "add_to_search_backend/3 indexes every chunk and records no failure",
         %{collection: collection, chunks: chunks} do
      indexed = index_all!(chunks, collection)

      assert length(indexed) == 5
      assert Repo.all(FailedIngest) == []

      all = Query.match(Query.new(collection, size: 30), "common", ParsedBook.search_fields())
      assert Enum.sort(ids(search!(all))) == Enum.sort(ids(chunks))
    end

    test "a chunk the server rejects is recorded as a FailedIngest under its id",
         %{collection: collection, book: book} do
      {:ok, bad} =
        Cake.Books.create_chunk(%{
          parsed_book_id: book.id,
          chunk_index: 99,
          text: "wrong dimension",
          word_count: 2,
          char_count: 15,
          embedding: [1.0, 0.0, 0.0]
        })

      assert [] = index_all!([bad], collection)

      assert [%FailedIngest{step: "search_backend.index", input_identifier: id}] =
               Repo.all(FailedIngest)

      assert id == bad.id
    end

    test "keyword hits hydrate through load_from_hits/1 in hit order with the book preloaded",
         %{collection: collection, chunks: chunks} do
      index_all!(chunks, collection)

      query = Query.match(Query.new(collection, size: 30), "needle", ParsedBook.search_fields())
      hits = search!(query)
      assert Enum.sort(ids(hits)) == Enum.sort([Enum.at(chunks, 1).id, Enum.at(chunks, 3).id])

      units = ParsedBook.load_from_hits(hits)

      assert ids(units) == ids(hits)
      assert Enum.all?(units, &match?(%Chunk{parsed_book: %ParsedBook{}}, &1))
    end

    test "vector hits hydrate with the nearest chunk first",
         %{collection: collection, chunks: chunks} do
      index_all!(chunks, collection)

      query = Query.knn(Query.new(collection, size: 30), "embedding", unit_vector(2), 30)
      [%Hit{score: top} | _] = hits = search!(query)
      assert top == 1.0

      [nearest | _rest] = ParsedBook.load_from_hits(hits)
      assert nearest.id == Enum.at(chunks, 2).id
      assert nearest.chunk_index == 2
    end

    test "expand_with_neighbors/2 widens a hit into its ordered neighbors from Postgres",
         %{collection: collection, chunks: chunks} do
      index_all!(chunks, collection)

      query = Query.knn(Query.new(collection, size: 1), "embedding", unit_vector(2), 30)
      [only] = ParsedBook.load_from_hits(search!(query))
      assert only.chunk_index == 2

      expanded = ParsedBook.expand_with_neighbors([only], 1)
      assert Enum.map(expanded, & &1.chunk_index) == [1, 2, 3]
      assert ids(expanded) == ids(Enum.slice(chunks, 1..3))
      assert Enum.all?(expanded, &match?(%Chunk{parsed_book: %ParsedBook{}}, &1))

      whole_book = ParsedBook.expand_with_neighbors([only], 2)
      assert Enum.map(whole_book, & &1.chunk_index) == [0, 1, 2, 3, 4]
    end
  end

  describe "ParsedDocument GDS" do
    setup %{collection: collection} do
      :ok = OpenSearch.create_collection(collection, OpenSearch.build_mapping(ParsedDocument))

      docs =
        for {title, axis} <- [{"Enum.map/2", 0}, {"needle: Enum.reduce/3", 1}, {"Kernel.if/2", 2}] do
          parsed_documents_fixture(%{
            title: title,
            text: "#{title} documentation needle text",
            embedding: unit_vector(axis)
          })
        end

      %{docs: docs}
    end

    test "add_to_search_backend/3 → keyword search → load_from_hits/1 hydrates in hit order",
         %{collection: collection, docs: docs} do
      assert length(index_all!(docs, collection)) == 3
      assert Repo.all(FailedIngest) == []

      query =
        Query.match(Query.new(collection, size: 30), "needle", ParsedDocument.search_fields())

      hits = search!(query)
      assert Enum.sort(ids(hits)) == Enum.sort(ids(docs))

      units = ParsedDocument.load_from_hits(hits)
      assert ids(units) == ids(hits)
      assert Enum.all?(units, &match?(%ParsedDocument{}, &1))
    end

    test "expand_with_neighbors/2 is the identity for an unordered GDS",
         %{collection: collection, docs: docs} do
      index_all!(docs, collection)

      query = Query.knn(Query.new(collection, size: 1), "embedding", unit_vector(1), 30)
      [nearest] = units = ParsedDocument.load_from_hits(search!(query))
      assert nearest.title == "needle: Enum.reduce/3"

      assert ParsedDocument.expand_with_neighbors(units, 2) == units
    end
  end
end
