defmodule Cake.Search.DeploymentTest do
  use ExUnit.Case, async: true

  alias Cake.Search.Backend.OpenSearch
  alias Cake.Search.Deployment
  alias Cake.Search.HTTPClientStub

  defp transport_error(reason), do: {:error, Snap.HTTPClient.Error.new(reason, :deployment_test)}

  # Serves this test's Snap requests with `reply` and reports each to the test.
  defp answer_every_request_with(reply) do
    test_pid = self()

    HTTPClientStub.put_responder(fn method, url, _headers, _body ->
      send(test_pid, {:request, method, URI.parse(url).path})
      reply
    end)
  end

  describe "create_missing_collections/1 (one pass, no retry)" do
    test "returns the failed step and the error when the cluster is unreachable" do
      answer_every_request_with(transport_error(:econnrefused))

      assert {:error, {"listing collections", %Snap.HTTPClient.Error{reason: :econnrefused}}} =
               Deployment.create_missing_collections(Deployment.collections())

      assert_received {:request, :get, "/_cat/indices"}
      refute_received {:request, _method, _path}
    end

    test "returns a 5xx the same way: the cluster is not there yet" do
      answer_every_request_with(
        HTTPClientStub.json_response(503, %{
          "error" => %{"type" => "cluster_block_exception", "reason" => "not recovered"},
          "status" => 503
        })
      )

      assert {:error, {"listing collections", %Snap.ResponseError{status: 503}}} =
               Deployment.create_missing_collections(Deployment.collections())
    end

    test "raises when the cluster refuses the request" do
      answer_every_request_with(
        HTTPClientStub.json_response(403, %{
          "error" => %{"type" => "security_exception", "reason" => "no permissions"},
          "status" => 403
        })
      )

      assert_raise RuntimeError, ~r/Application error listing collections: Status 403/, fn ->
        Deployment.create_missing_collections(Deployment.collections())
      end
    end
  end

  describe "create_collections_unless_exist/2 (one pass, no retry)" do
    test "raises on a transport error, naming the reason, after its one request" do
      answer_every_request_with(transport_error(:econnrefused))

      assert_raise RuntimeError,
                   ~r/Transport-layer error listing collections.*econnrefused/s,
                   fn ->
                     Deployment.create_collections_unless_exist(
                       Process.whereis(Deployment),
                       Deployment.collections()
                     )
                   end

      assert_received {:request, :get, "/_cat/indices"}
      refute_received {:request, _method, _path}
    end
  end

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
