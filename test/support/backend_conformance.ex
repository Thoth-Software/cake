defmodule Cake.Search.BackendConformance do
  @moduledoc """
  Shared conformance suite for `Cake.Search.Backend` implementations (#245).

  A backend instantiates it against a real server:

      defmodule Cake.Search.Backend.OpenSearchConformanceTest do
        use Cake.Search.BackendConformance,
          backend: Cake.Search.Backend.OpenSearch,
          mapping: Cake.Search.Backend.OpenSearch.build_mapping(Cake.Books.Chunk)
      end

  `:backend` is the module under test; `:mapping` is the backend-specific
  collection schema for a Cake retrieval unit (a document with an `id`, a
  `text` field and an `embedding` vector of the configured dimension). The
  suite builds on `Cake.SearchIntegrationCase`, so it runs only with
  `mix test --only integration` and every test works in its own collection.

  The groups are the behaviour's contract as Cake relies on it. Every
  backend — OpenSearch today, Slice (#195) and any later one — must pass
  them unchanged. Each group is a macro that registers the tests; each test
  body is a plain function here, so a backend author can also call one
  directly while debugging.

  Stub: the lifecycle group is written; `backend/0` and
  `collection_mapping/0` are not wired to the `use` options yet, so the
  group fails on that missing wiring.
  """

  import ExUnit.Assertions

  alias Cake.Search.Hit
  alias Cake.Search.Query
  alias Cake.SearchIntegrationCase

  @typedoc "The `use` options: the backend module and its collection mapping."
  @type wiring :: %{backend: module(), mapping: map()}

  @doc false
  defmacro __using__(opts) do
    async = Keyword.get(opts, :async, true)

    quote do
      use Cake.SearchIntegrationCase, async: unquote(async)

      require Cake.Search.BackendConformance

      @doc false
      @spec backend() :: module()
      def backend, do: raise("Cake.Search.BackendConformance: :backend is not wired yet (#245)")

      @doc false
      @spec collection_mapping() :: map()
      def collection_mapping,
        do: raise("Cake.Search.BackendConformance: :mapping is not wired yet (#245)")

      @doc false
      @spec wiring() :: Cake.Search.BackendConformance.wiring()
      def wiring, do: %{backend: backend(), mapping: collection_mapping()}

      Cake.Search.BackendConformance.lifecycle_group()
    end
  end

  @lifecycle_tests [
    {"create_collection/2 creates a collection that list_collections/0 reports",
     :creates_collection},
    {"create_collection/2 on an existing collection is an error that leaves it in place",
     :rejects_duplicate_collection},
    {"list_collections/0 omits a collection that was never created", :omits_unknown_collection},
    {"index_document/3 inserts a document under the given id", :inserts_document},
    {"index_document/3 with an existing id updates in place rather than duplicating",
     :upserts_document},
    {"delete_document/2 removes the document and leaves the others", :deletes_document}
  ]

  @doc """
  Collection lifecycle: `create_collection/2` (including the already-exists
  case), `list_collections/0`, `index_document/3` upsert semantics and
  `delete_document/2`.
  """
  defmacro lifecycle_group do
    register_group("conformance — collection lifecycle", @lifecycle_tests)
  end

  # Registers one `describe` block whose tests each call the named body in
  # this module with the instantiating module's wiring and the test context.
  defp register_group(describe, tests) do
    registrations =
      Enum.map(tests, fn {name, body} ->
        quote do
          test unquote(name), ctx do
            Cake.Search.BackendConformance.unquote(body)(wiring(), ctx)
          end
        end
      end)

    quote do
      describe unquote(describe) do
        (unquote_splicing(registrations))
      end
    end
  end

  # -- lifecycle group bodies -----------------------------------------------

  @doc false
  @spec creates_collection(wiring(), map()) :: true
  def creates_collection(%{backend: backend, mapping: mapping}, %{collection: collection}) do
    assert :ok = backend.create_collection(collection, mapping)

    assert {:ok, listed} = backend.list_collections()
    assert collection in listed
  end

  @doc false
  @spec rejects_duplicate_collection(wiring(), map()) :: true
  def rejects_duplicate_collection(%{backend: backend, mapping: mapping}, %{
        collection: collection
      }) do
    assert :ok = backend.create_collection(collection, mapping)

    assert {:error, _reason} = backend.create_collection(collection, mapping)

    assert {:ok, listed} = backend.list_collections()
    assert Enum.count(listed, &(&1 == collection)) == 1
  end

  @doc false
  @spec omits_unknown_collection(wiring(), map()) :: false
  def omits_unknown_collection(%{backend: backend}, ctx) do
    never_created = SearchIntegrationCase.unique_collection_name(ctx)

    assert {:ok, listed} = backend.list_collections()
    refute never_created in listed
  end

  @doc false
  @spec inserts_document(wiring(), map()) :: true
  def inserts_document(%{backend: backend, mapping: mapping}, %{collection: collection}) do
    assert :ok = backend.create_collection(collection, mapping)

    assert :ok = backend.index_document(collection, %{id: "d1", text: "first draft"}, "d1")
    SearchIntegrationCase.refresh!(collection)

    query = Query.match(Query.new(collection), "first", ["text"])
    assert {:ok, [%Hit{id: "d1", source: %{"text" => "first draft"}}]} = backend.search(query)
  end

  @doc false
  @spec upserts_document(wiring(), map()) :: true
  def upserts_document(%{backend: backend, mapping: mapping}, %{collection: collection}) do
    assert :ok = backend.create_collection(collection, mapping)
    assert :ok = backend.index_document(collection, %{id: "d1", text: "first draft"}, "d1")
    assert :ok = backend.index_document(collection, %{id: "d1", text: "second draft"}, "d1")
    SearchIntegrationCase.refresh!(collection)

    updated = Query.match(Query.new(collection), "second", ["text"])
    assert {:ok, [%Hit{id: "d1", source: %{"text" => "second draft"}}]} = backend.search(updated)

    stale = Query.match(Query.new(collection), "first", ["text"])
    assert {:ok, []} = backend.search(stale)
  end

  @doc false
  @spec deletes_document(wiring(), map()) :: true
  def deletes_document(%{backend: backend, mapping: mapping}, %{collection: collection}) do
    assert :ok = backend.create_collection(collection, mapping)
    assert :ok = backend.index_document(collection, %{id: "d1", text: "shared token"}, "d1")
    assert :ok = backend.index_document(collection, %{id: "d2", text: "shared token"}, "d2")
    SearchIntegrationCase.refresh!(collection)

    assert :ok = backend.delete_document(collection, "d1")
    SearchIntegrationCase.refresh!(collection)

    query = Query.match(Query.new(collection), "shared", ["text"])
    assert {:ok, [%Hit{id: "d2"}]} = backend.search(query)
  end
end
