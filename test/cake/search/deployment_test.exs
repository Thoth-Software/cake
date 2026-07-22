defmodule Cake.Search.DeploymentTest do
  use ExUnit.Case, async: true

  alias Cake.Search.Backend.OpenSearch
  alias Cake.Search.Deployment

  describe "collections/0" do
    test "reads the collection list from :search_collections config" do
      # Each entry is {name_module, mapping_schema}: the first supplies the
      # collection name via collection_name/0, the second the index mapping.
      collections = Deployment.collections()

      assert {Cake.Documents.ParsedDocument, Cake.Documents.ParsedDocument} in collections
      assert {Cake.Books.ParsedBook, Cake.Books.Chunk} in collections
    end

    test "is overridable via application config" do
      original = Application.get_env(:cake, :search_collections)
      override = [{Cake.Books.ParsedBook, Cake.Books.Chunk}]
      Application.put_env(:cake, :search_collections, override)
      on_exit(fn -> Application.put_env(:cake, :search_collections, original) end)

      assert Deployment.collections() == override
    end
  end

  describe "build_mapping/1" do
    test "maps :text fields to OpenSearch text type" do
      mapping = OpenSearch.build_mapping(Cake.Documents.ParsedDocument)
      props = mapping.mappings.properties

      assert props.text == %{type: "text"}
    end

    test "maps :embedding field to knn_vector with HNSW config" do
      mapping = OpenSearch.build_mapping(Cake.Documents.ParsedDocument)
      embedding = mapping.mappings.properties.embedding

      assert embedding.type == "knn_vector"
      assert embedding.dimension == 1536
      assert embedding.method.name == "hnsw"
      assert embedding.method.space_type == "cosinesimil"
      assert embedding.method.engine == "faiss"
    end

    test "reads vector dimension from application config" do
      Application.put_env(:cake, :default_embedding_dimension, 3072)
      on_exit(fn -> Application.delete_env(:cake, :default_embedding_dimension) end)

      mapping = OpenSearch.build_mapping(Cake.Documents.ParsedDocument)
      embedding = mapping.mappings.properties.embedding

      assert embedding.dimension == 3072
    end

    test "maps non-text, non-embedding fields as keyword" do
      mapping = OpenSearch.build_mapping(Cake.Documents.ParsedDocument)
      props = mapping.mappings.properties

      assert props.source == %{type: "keyword"}
      assert props.version == %{type: "keyword"}
      assert props.package == %{type: "keyword"}
    end

    test "includes knn settings" do
      mapping = OpenSearch.build_mapping(Cake.Documents.ParsedDocument)

      assert mapping.settings["index.knn"] == true
    end

    test "works with Chunk schema" do
      mapping = OpenSearch.build_mapping(Cake.Books.Chunk)
      props = mapping.mappings.properties

      assert props.text == %{type: "text"}
      assert props.embedding.type == "knn_vector"
      assert props[:chunk_index] == %{type: "keyword"}
    end
  end
end
