defmodule Cake.Documents.ParsedDocumentGDSTest do
  use Cake.DataCase

  import Cake.ParsedDocumentFixtures

  alias Cake.Documents.ParsedDocument

  describe "Cake.GDS contract" do
    test "declares @behaviour Cake.GDS" do
      behaviours = ParsedDocument.__info__(:attributes)[:behaviour] || []
      assert Cake.GDS in behaviours
    end

    test "index_name/0 returns the docs index name" do
      assert ParsedDocument.index_name() == "docs"
    end

    test "search_fields/0 returns title (boost 3) and text" do
      assert ParsedDocument.search_fields() == ["title^3", "text"]
    end

    test "load_from_hits/1 hydrates parsed documents from hit IDs in hit order" do
      doc_a =
        parsed_documents_fixture(%{
          title: "doc_a",
          url: "https://example.com/a",
          package: "Alpha",
          source: "hexdocs",
          version: "1.0.0",
          text: "alpha text"
        })

      doc_b =
        parsed_documents_fixture(%{
          title: "doc_b",
          url: "https://example.com/b",
          package: "Beta",
          source: "hexdocs",
          version: "1.0.0",
          text: "beta text"
        })

      hits = [
        %Snap.Hit{source: %{"id" => doc_b.id}},
        %Snap.Hit{source: %{"id" => doc_a.id}}
      ]

      loaded = ParsedDocument.load_from_hits(hits)

      assert Enum.map(loaded, & &1.id) == [doc_b.id, doc_a.id]
    end

    test "expand_with_neighbors/2 returns input unchanged (identity default)" do
      docs = [
        %ParsedDocument{id: Ecto.UUID.generate()},
        %ParsedDocument{id: Ecto.UUID.generate()}
      ]

      assert ParsedDocument.expand_with_neighbors(docs, 5) == docs
      assert ParsedDocument.expand_with_neighbors(docs, 0) == docs
      assert ParsedDocument.expand_with_neighbors([], 10) == []
    end
  end
end
