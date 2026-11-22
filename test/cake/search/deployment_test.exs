defmodule Cake.Search.DeploymentTest do
  use ExUnit.Case, async: true

  alias Cake.Search.Backend.OpenSearch
  alias Cake.Search.Deployment
  alias Cake.Search.HTTPClientStub

  # Characterization (#363, box 1): what the code does today when the first
  # `list_collections/0` of the boot pass fails with a transport error. These
  # pin current behaviour, not the wanted one; the contract tests of box 2
  # replace them.
  describe "when the first list_collections/0 fails with a transport error (characterization)" do
    test "create_collections_unless_exist/2 raises a MatchError and attempts nothing else" do
      test_pid = self()

      HTTPClientStub.put_responder(fn method, url, _headers, _body ->
        send(test_pid, {:request, method, URI.parse(url).path})
        {:error, Snap.HTTPClient.Error.new(:econnrefused, :characterization)}
      end)

      error =
        assert_raise MatchError, fn ->
          Deployment.create_collections_unless_exist(
            Process.whereis(Deployment),
            Deployment.collections()
          )
        end

      assert {:error, %Snap.HTTPClient.Error{reason: :econnrefused}} = error.term

      # One list request, no retry, no create.
      assert_received {:request, :get, "/_cat/indices"}
      refute_received {:request, _method, _path}
    end

    # The boot path proper. `init/1` runs in whichever process calls the
    # cluster's `start_link/1` (Snap calls `init/1` before it starts its own
    # supervisor), so the task it links is linked to that caller: under the
    # application that is `Cake.Supervisor`, here it is the test process,
    # trapping exits as a supervisor does. The task has no stub responder, so
    # its one request gets the stub's transport error, as against an
    # unreachable cluster. Nothing here sleeps: the 10 s are the task's own
    # hard-coded wait, and the test blocks on the exit signal.
    @tag capture_log: true
    @tag timeout: 30_000
    test "the task init/1 links dies with that MatchError after its one attempt; its caller and the Deployment live on" do
      Process.flag(:trap_exit, true)
      deployment = Process.whereis(Deployment)
      {:links, links_before} = Process.info(self(), :links)

      assert {:ok, []} = Deployment.init([])

      {:links, links_after} = Process.info(self(), :links)
      assert [task] = links_after -- links_before

      assert_receive {:EXIT, ^task, {{:badmatch, {:error, error}}, _stacktrace}}, 15_000
      assert %Snap.HTTPClient.Error{reason: :no_responder} = error

      # Nothing retries (the task was the only thing that would), and nothing
      # else went down with it.
      assert Process.whereis(Deployment) == deployment
      assert Process.alive?(deployment)
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
