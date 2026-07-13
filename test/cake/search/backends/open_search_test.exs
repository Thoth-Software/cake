defmodule Cake.Search.Backends.OpenSearchTest do
  use ExUnit.Case, async: true

  alias Cake.Search.Backends.OpenSearch
  alias Cake.Search.Query

  describe "to_query_map/1" do
    test "produces the expected nested structure for a known input" do
      vector = [0.1, 0.2]
      base = Query.new("docs", size: 5, min_score: 0.4)

      result =
        base
        |> Query.knn("embedding", vector, 3)
        |> Query.match("Supervisor", ["title"])
        |> Query.filter_term("language", "Elixir")
        |> OpenSearch.to_query_map()

      assert result.size == 5
      assert result.min_score == 0.4

      assert result.query.bool.must == [
               %{"knn" => %{"embedding" => %{"vector" => vector, "k" => 3}}}
             ]

      assert result.query.bool.should == [
               %{
                 "multi_match" => %{
                   "query" => "Supervisor",
                   "fields" => ["title"],
                   "boost" => 1.0
                 }
               }
             ]

      assert result.query.bool.filter == [%{"term" => %{"language" => "Elixir"}}]
    end

    test "omits min_score when nil" do
      result = OpenSearch.to_query_map(Query.new("docs"))
      refute Map.has_key?(result, :min_score)
    end

    test "preserves clause insertion order" do
      base = Query.new("docs")

      result =
        base
        |> Query.filter_term("a", "first")
        |> Query.filter_term("b", "second")
        |> Query.filter_term("c", "third")
        |> OpenSearch.to_query_map()

      assert result.query.bool.filter == [
               %{"term" => %{"a" => "first"}},
               %{"term" => %{"b" => "second"}},
               %{"term" => %{"c" => "third"}}
             ]
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
