defmodule Cake.Search.Backend.OpenSearchMappingIntegrationTest do
  @moduledoc """
  `Cake.Search.Backend.OpenSearch.build_mapping/1` against a real node
  (#245): the mapping generated for each GDS schema must be accepted as
  written, come back from the server with the k-NN field configured as
  Cake intends (`knn_vector`, dimension 1536, HNSW on FAISS, cosine), and
  accept a real record of that schema as a document. The unit tests in
  `open_search_test.exs` only check the map Cake builds; this checks what
  the server makes of it. Runs with `mix test --only integration`.
  """

  use Cake.SearchIntegrationCase, async: true

  import Cake.BooksFixtures
  import Cake.ParsedDocumentFixtures

  alias Cake.Books.Chunk
  alias Cake.Documents.ParsedDocument
  alias Cake.Search.Backend.OpenSearch
  alias Cake.Search.Deployment

  @knn_field %{
    "type" => "knn_vector",
    "dimension" => 1536,
    "method" => %{
      "name" => "hnsw",
      "engine" => "faiss",
      "space_type" => "cosinesimil",
      "parameters" => %{"ef_construction" => 512, "m" => 16}
    }
  }

  describe "build_mapping(Cake.Books.Chunk)" do
    test "is accepted and comes back with the fields typed as built", %{collection: collection} do
      assert :ok = OpenSearch.create_collection(collection, OpenSearch.build_mapping(Chunk))

      properties = server_mapping!(collection)
      assert properties["text"] == %{"type" => "text"}
      assert properties["embedding"] == @knn_field
      assert properties["chunk_index"] == %{"type" => "keyword"}
      assert properties["parsed_book_id"] == %{"type" => "keyword"}
    end

    test "applies the knn and refresh settings", %{collection: collection} do
      assert :ok = OpenSearch.create_collection(collection, OpenSearch.build_mapping(Chunk))

      settings = server_settings!(collection)
      assert settings["knn"] == "true"
      assert settings["refresh_interval"] == "30s"
    end

    test "accepts a persisted Chunk as a document", %{collection: collection} do
      assert :ok = OpenSearch.create_collection(collection, OpenSearch.build_mapping(Chunk))
      chunk = chunk_fixture(%{embedding: List.replace_at(List.duplicate(0.0, 1536), 1535, 1.0)})

      assert :ok = OpenSearch.index_document(collection, chunk, chunk.id)
      refresh!(collection)

      {:ok, %{"_source" => source}} = Deployment.get("/cake_test-#{collection}/_doc/#{chunk.id}")
      assert source["id"] == chunk.id
      assert source["text"] == chunk.text
      assert source["chunk_index"] == chunk.chunk_index
      assert length(source["embedding"]) == 1536
    end
  end

  describe "build_mapping(Cake.Documents.ParsedDocument)" do
    test "is accepted and comes back with the fields typed as built", %{collection: collection} do
      mapping = OpenSearch.build_mapping(ParsedDocument)
      assert :ok = OpenSearch.create_collection(collection, mapping)

      properties = server_mapping!(collection)
      assert properties["text"] == %{"type" => "text"}
      assert properties["embedding"] == @knn_field
      assert properties["package"] == %{"type" => "keyword"}
      assert properties["url"] == %{"type" => "keyword"}
    end

    test "accepts a persisted ParsedDocument as a document", %{collection: collection} do
      mapping = OpenSearch.build_mapping(ParsedDocument)
      assert :ok = OpenSearch.create_collection(collection, mapping)
      doc = parsed_documents_fixture(%{embedding: [1.0 | List.duplicate(0.0, 1535)]})

      assert :ok = OpenSearch.index_document(collection, doc, doc.id)
      refresh!(collection)

      {:ok, %{"_source" => source}} = Deployment.get("/cake_test-#{collection}/_doc/#{doc.id}")
      assert source["id"] == doc.id
      assert source["package"] == doc.package
      assert source["core"] == true
    end
  end

  describe "the collections Deployment creates at boot" do
    test "every configured {name_module, schema} pair yields an accepted mapping", context do
      configured = Deployment.collections()
      assert configured != []

      for {name_module, schema} <- configured do
        collection = unique_collection_name(context)
        mapping = OpenSearch.build_mapping(schema)

        assert :ok = OpenSearch.create_collection(collection, mapping),
               "#{inspect(schema)} mapping for #{name_module.collection_name()} was rejected"

        assert server_mapping!(collection)["embedding"] == @knn_field
      end
    end
  end
end
