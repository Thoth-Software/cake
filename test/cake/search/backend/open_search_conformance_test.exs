defmodule Cake.Search.Backend.OpenSearchConformanceTest do
  @moduledoc """
  `Cake.Search.Backend.OpenSearch` against a real OpenSearch node, through
  the shared `Cake.Search.BackendConformance` suite (#245). The mapping is
  the production one for the Books retrieval unit, so the suite also
  exercises `build_mapping/1` end to end. Runs with
  `mix test --only integration`.

  The trailing describe block is OpenSearch-specific: how the server
  combines the vector `must` and the keyword `should` into one score. The
  shared suite states the hybrid contract in ranking terms only, so a
  backend with a different fusion can pass it; the additive arithmetic
  Cake's ranking sees today is pinned here.
  """

  use Cake.Search.BackendConformance,
    backend: Cake.Search.Backend.OpenSearch,
    mapping: Cake.Search.Backend.OpenSearch.build_mapping(Cake.Books.Chunk)

  alias Cake.Search.BackendConformance

  describe "OpenSearch-specific — hybrid scoring is additive" do
    test "a keyword match in should adds to the document's vector score",
         %{collection: collection} do
      BackendConformance.seed_corpus!(wiring(), collection)

      {vector_hits, hybrid_hits} =
        BackendConformance.vector_and_hybrid_hits(wiring(), collection, "GenServer")

      for id <- ["alpha", "gamma"] do
        assert BackendConformance.score_of(hybrid_hits, id) >
                 BackendConformance.score_of(vector_hits, id),
               "#{id} matches the keyword clause and must score higher in hybrid"
      end
    end

    test "a document outside the keyword match keeps exactly its vector score",
         %{collection: collection} do
      BackendConformance.seed_corpus!(wiring(), collection)

      {vector_hits, hybrid_hits} =
        BackendConformance.vector_and_hybrid_hits(wiring(), collection, "GenServer")

      assert_in_delta BackendConformance.score_of(hybrid_hits, "beta"),
                      BackendConformance.score_of(vector_hits, "beta"),
                      1.0e-6
    end
  end
end
