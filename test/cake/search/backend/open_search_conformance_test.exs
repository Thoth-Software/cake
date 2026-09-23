defmodule Cake.Search.Backend.OpenSearchConformanceTest do
  @moduledoc """
  `Cake.Search.Backend.OpenSearch` against a real OpenSearch node, through
  the shared `Cake.Search.BackendConformance` suite (#245). The mapping is
  the production one for the Books retrieval unit, so the suite also
  exercises `build_mapping/1` end to end. Runs with
  `mix test --only integration`.
  """

  use Cake.Search.BackendConformance,
    backend: Cake.Search.Backend.OpenSearch,
    mapping: Cake.Search.Backend.OpenSearch.build_mapping(Cake.Books.Chunk)
end
