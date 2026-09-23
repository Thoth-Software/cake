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
  """

  import ExUnit.Assertions

  alias Cake.Search.Hit
  alias Cake.Search.Query
  alias Cake.SearchIntegrationCase

  @typedoc "The `use` options: the backend module and its collection mapping."
  @type wiring :: %{backend: module(), mapping: map()}

  @doc false
  defmacro __using__(opts) do
    backend = Keyword.fetch!(opts, :backend)
    mapping = Keyword.fetch!(opts, :mapping)
    async = Keyword.get(opts, :async, true)

    quote do
      use Cake.SearchIntegrationCase, async: unquote(async)

      require Cake.Search.BackendConformance

      @doc false
      @spec backend() :: module()
      def backend, do: unquote(backend)

      # Evaluated per call, not at compile time: a mapping expression may
      # read application config (`build_mapping/1` reads the embedding
      # dimension).
      @doc false
      @spec collection_mapping() :: map()
      def collection_mapping, do: unquote(mapping)

      @doc false
      @spec wiring() :: Cake.Search.BackendConformance.wiring()
      def wiring, do: %{backend: backend(), mapping: collection_mapping()}

      Cake.Search.BackendConformance.lifecycle_group()
      Cake.Search.BackendConformance.search_modes_group()
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

  @search_modes_tests [
    {":keyword — match/4 returns exactly the documents containing the term, best first",
     :keyword_search},
    {":vector — knn/5 with k=30 ranks the identical vector first and returns every neighbor",
     :vector_search},
    {":hybrid — a keyword match in should raises a document above its vector-only score",
     :hybrid_search},
    {":hybrid — a document outside the keyword match keeps its vector-only score",
     :hybrid_keeps_vector_score},
    {"min_score drops every hit scoring below it", :min_score},
    {"size caps the number of hits", :size},
    {"search/1 accepts the vector query Cake.Search builds (its k and ef_search defaults)",
     :accepts_cake_search_vector_query}
  ]

  @doc """
  Search modes over a seeded corpus: `:keyword` (BM25 `multi_match`),
  `:vector` (kNN over `embedding`, cosine, `k` 30), `:hybrid` (vector in
  `must`, boosted keyword in `should`), `min_score` and `size`, plus the
  exact vector query `Cake.Search` builds.
  """
  defmacro search_modes_group do
    register_group("conformance — search modes", @search_modes_tests)
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

  # -- search-modes group: corpus ----------------------------------------------

  # "alpha" and "gamma" mention GenServer, "beta" does not; all three mention
  # Elixir. Each document's embedding is the unit vector on its axis.
  @corpus [
    %{id: "alpha", text: "GenServer callbacks handle_call and handle_cast in Elixir", axis: 0},
    %{id: "beta", text: "Supervisor restart strategies in Elixir", axis: 1},
    %{id: "gamma", text: "A GenServer under a Supervisor in Elixir", axis: 2}
  ]

  @doc """
  Creates `collection` with the wiring's mapping, indexes the fixed corpus
  into it and refreshes. Returns the corpus: maps with `:id`, `:text` and
  `:embedding`, each embedding a unit vector on its own axis so cosine
  scores are exact (1.0 for the same document, 0.5 for any other).
  """
  @spec seed_corpus!(wiring(), String.t()) :: [map()]
  def seed_corpus!(%{backend: backend, mapping: mapping}, collection) do
    :ok = backend.create_collection(collection, mapping)

    corpus =
      Enum.map(@corpus, fn %{id: id, text: text, axis: axis} ->
        %{id: id, text: text, embedding: unit_vector(axis)}
      end)

    Enum.each(corpus, fn doc -> :ok = backend.index_document(collection, doc, doc.id) end)
    SearchIntegrationCase.refresh!(collection)

    corpus
  end

  @doc "The unit vector on `axis`, in the configured embedding dimension."
  @spec unit_vector(non_neg_integer()) :: [float()]
  def unit_vector(axis) when is_integer(axis) and axis >= 0 do
    dimension = Application.get_env(:cake, :default_embedding_dimension, 1536)

    0.0
    |> List.duplicate(dimension)
    |> List.replace_at(axis, 1.0)
  end

  # -- search-modes group bodies ----------------------------------------------

  @doc false
  @spec keyword_search(wiring(), map()) :: true
  def keyword_search(%{backend: backend} = wiring, %{collection: collection}) do
    seed_corpus!(wiring, collection)

    query = Query.match(Query.new(collection), "GenServer", ["text"])
    assert {:ok, hits} = backend.search(query)

    assert ids(hits) == ["alpha", "gamma"]
    assert sorted_by_score?(hits)
    assert Enum.all?(hits, &scored_text_hit?(&1, "GenServer"))
  end

  @doc false
  @spec vector_search(wiring(), map()) :: true
  def vector_search(%{backend: backend} = wiring, %{collection: collection}) do
    corpus = seed_corpus!(wiring, collection)

    query = Query.knn(Query.new(collection, size: 30), "embedding", unit_vector(1), 30)
    assert {:ok, [%Hit{id: "beta", score: top} | rest] = hits} = backend.search(query)

    assert ids(hits) == ids(corpus)
    assert Enum.all?(rest, &(&1.score < top))
    assert sorted_by_score?(hits)
  end

  @doc false
  @spec hybrid_search(wiring(), map()) :: true
  def hybrid_search(wiring, %{collection: collection}) do
    seed_corpus!(wiring, collection)
    {vector_hits, hybrid_hits} = vector_and_hybrid_hits(wiring, collection)

    # Same candidates (the vector clause is the must), re-scored: the
    # documents matching the keyword clause gain, the rest do not.
    assert ids(hybrid_hits) == ids(vector_hits)
    assert score_of(hybrid_hits, "alpha") > score_of(vector_hits, "alpha")
    assert score_of(hybrid_hits, "gamma") > score_of(vector_hits, "gamma")
  end

  @doc false
  @spec hybrid_keeps_vector_score(wiring(), map()) :: true
  def hybrid_keeps_vector_score(wiring, %{collection: collection}) do
    seed_corpus!(wiring, collection)
    {vector_hits, hybrid_hits} = vector_and_hybrid_hits(wiring, collection)

    assert_in_delta score_of(hybrid_hits, "beta"), score_of(vector_hits, "beta"), 1.0e-6
  end

  @doc false
  @spec min_score(wiring(), map()) :: true
  def min_score(%{backend: backend} = wiring, %{collection: collection}) do
    seed_corpus!(wiring, collection)

    base = Query.knn(Query.new(collection, size: 30), "embedding", unit_vector(1), 30)
    assert {:ok, all_hits} = backend.search(base)
    assert length(all_hits) == 3

    assert {:ok, [%Hit{id: "beta"}]} = backend.search(Query.min_score(base, 0.9))
  end

  @doc false
  @spec size(wiring(), map()) :: true
  def size(%{backend: backend} = wiring, %{collection: collection}) do
    seed_corpus!(wiring, collection)

    all = Query.match(Query.new(collection, size: 30), "Elixir", ["text"])
    assert {:ok, hits} = backend.search(all)
    assert length(hits) == 3

    assert {:ok, two} = backend.search(Query.size(all, 2))
    assert length(two) == 2

    assert {:ok, [_one]} = backend.search(Query.size(all, 1))
  end

  @doc false
  @spec accepts_cake_search_vector_query(wiring(), map()) :: true
  def accepts_cake_search_vector_query(%{backend: backend} = wiring, %{collection: collection}) do
    seed_corpus!(wiring, collection)

    # The clause Cake.Search.build_query/6 emits for :vector and :hybrid.
    query =
      Query.knn(
        Query.new(collection, size: Cake.Search.default_size()),
        "embedding",
        unit_vector(1),
        Cake.Search.default_k(),
        ef_search: Cake.Search.default_ef_search()
      )

    assert {:ok, [%Hit{id: "beta"} | _rest]} = backend.search(query)
  end

  # Vector-only hits and the hits of the same query with a boosted keyword
  # clause in should — Cake.Search's :hybrid shape with its default weight.
  defp vector_and_hybrid_hits(%{backend: backend}, collection) do
    vector_only = Query.knn(Query.new(collection, size: 30), "embedding", unit_vector(1), 30)
    hybrid = Query.match(vector_only, "GenServer", ["text"], boost: 0.8)

    {:ok, vector_hits} = backend.search(vector_only)
    {:ok, hybrid_hits} = backend.search(hybrid)
    {vector_hits, hybrid_hits}
  end

  defp ids(hits_or_docs) do
    hits_or_docs |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp scored_text_hit?(%Hit{score: score, source: source}, term) do
    is_float(score) and score > 0 and source["text"] =~ term
  end

  defp sorted_by_score?(hits) do
    scores = Enum.map(hits, & &1.score)
    scores == Enum.sort(scores, :desc)
  end

  defp score_of(hits, id) do
    %Hit{score: score} = Enum.find(hits, &(&1.id == id))
    score
  end
end
