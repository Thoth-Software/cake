defmodule Cake.SearchIntegrationCaseTest do
  @moduledoc """
  Contract for `Cake.SearchIntegrationCase`, the case template every real-
  cluster test builds on (#245).

  The template must:

    * tag its tests `:integration` and neutralize the `skip_search_backend`
      flag that `test_helper.exs` sets for unit runs;
    * point `Cake.Search.Deployment` at a real cluster (not the
      `Cake.Search.HTTPClientStub` adapter from `config/test.exs`), inside the
      `cake_test` index namespace so a developer's real `docs` and
      `chunks_of_books` indices are never touched;
    * hand each test a collection name unique to it, plus a way to derive
      further names under the same prefix;
    * expose `refresh!/1`, because the production mapping sets
      `index.refresh_interval` to 30s and nothing indexed is searchable
      before a refresh;
    * drop every collection a test created once the test is over.

  Teardown cannot be observed from inside the test that triggers it
  (`on_exit` callbacks run newest-first, so a test-body callback runs
  before the template's), so the tests record what they created in a
  ledger and the `setup_all` `on_exit` — which runs after every test in the
  module and all their callbacks — asserts the cluster no longer has any of
  it.
  """

  use Cake.SearchIntegrationCase, async: true

  alias Cake.Search.Backend.OpenSearch
  alias Cake.Search.Deployment
  alias Cake.Search.Hit
  alias Cake.Search.Query

  @mapping OpenSearch.build_mapping(Cake.Books.Chunk)

  setup_all do
    {:ok, ledger} = Agent.start(fn -> [] end)

    on_exit(fn ->
      created = Agent.get(ledger, & &1)
      Agent.stop(ledger)

      assert created != [], "no test recorded a collection in the ledger"
      assert Enum.uniq(created) == created, "two tests were handed the same collection name"

      {:ok, existing} = OpenSearch.list_collections()
      leftovers = Enum.filter(created, &(&1 in existing))
      assert leftovers == [], "collections survived their test's teardown: #{inspect(leftovers)}"
    end)

    %{ledger: ledger}
  end

  defp record(ledger, name), do: Agent.update(ledger, &[name | &1])

  describe "real-backend configuration" do
    test "tags every test :integration", context do
      assert context[:integration] == true
    end

    test "neutralizes skip_search_backend for its tests" do
      assert Application.get_env(:cake, :skip_search_backend) == false
    end

    test "routes Cake.Search.Deployment at a real cluster", %{collection: collection} do
      refute Keyword.get(Deployment.config(), :http_client_adapter) == Cake.Search.HTTPClientStub

      # A round trip the stub adapter cannot fake: create, then see it listed.
      assert :ok = OpenSearch.create_collection(collection, @mapping)
      assert {:ok, collections} = OpenSearch.list_collections()
      assert collection in collections
    end

    test "scopes every collection under the cake_test namespace", %{collection: collection} do
      assert Keyword.get(Deployment.config(), :index_namespace) == "cake_test"

      assert :ok = OpenSearch.create_collection(collection, @mapping)

      # The raw index name on the server carries the namespace; the
      # convenience API strips it again on the way back.
      {:ok, raw} = Deployment.get("/_cat/indices", format: "json")
      raw_names = Enum.map(raw, & &1["index"])
      assert "cake_test-#{collection}" in raw_names
      refute collection in raw_names

      assert {:ok, listed} = OpenSearch.list_collections()
      assert collection in listed
    end
  end

  describe "unique per-test collection names" do
    test "hands each test a :collection that does not exist yet", %{collection: collection} do
      assert collection =~ ~r/^it_[0-9a-f]{16}$/
      assert {:ok, existing} = OpenSearch.list_collections()
      refute collection in existing
    end

    test "unique_collection_name/1 derives distinct names under the test's prefix", context do
      first = unique_collection_name(context)
      second = unique_collection_name(context)

      assert first != second
      assert String.starts_with?(first, context.collection <> "_")
      assert String.starts_with?(second, context.collection <> "_")
    end

    test "names differ between tests (checked in the setup_all teardown)", context do
      record(context.ledger, context.collection)
    end

    test "names differ between tests, second sample", context do
      record(context.ledger, context.collection)
    end
  end

  describe "refresh!/1" do
    test "makes documents indexed since the last refresh searchable", %{collection: collection} do
      assert :ok = OpenSearch.create_collection(collection, @mapping)
      assert :ok = OpenSearch.index_document(collection, %{id: "d1", text: "sentinel"}, "d1")

      assert :ok = refresh!(collection)

      query = Query.match(Query.new(collection), "sentinel", ["text"])
      assert {:ok, [%Hit{id: "d1", source: %{"text" => "sentinel"}}]} = OpenSearch.search(query)
    end

    test "raises when the collection does not exist", context do
      missing = unique_collection_name(context)

      assert_raise RuntimeError, ~r/#{missing}/, fn -> refresh!(missing) end
    end
  end

  describe "automatic teardown" do
    test "drops the test's collection once the test is over", context do
      assert :ok = OpenSearch.create_collection(context.collection, @mapping)
      record(context.ledger, context.collection)
    end

    test "drops derived collections too", context do
      derived = unique_collection_name(context)
      assert :ok = OpenSearch.create_collection(derived, @mapping)
      record(context.ledger, derived)
    end

    test "drop_collections!/1 is idempotent for a prefix with nothing under it", context do
      assert :ok = drop_collections!(unique_collection_name(context))
    end
  end
end
