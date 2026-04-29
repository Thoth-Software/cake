defmodule Cake.Search.OpenSearchTest do
  use ExUnit.Case, async: false

  alias Cake.Search.OpenSearch
  alias Cake.Search.Query
  alias Cake.Support.FixtureGDS

  describe "default accessors" do
    test "default_size/0" do
      assert OpenSearch.default_size() == 30
    end

    test "default_k/0" do
      assert OpenSearch.default_k() == 30
    end

    test "default_ef_search/0" do
      assert OpenSearch.default_ef_search() == 256
    end

    test "default_keyword_weight/0" do
      assert OpenSearch.default_keyword_weight() == 0.8
    end

    test "default_expand_offset/0" do
      assert OpenSearch.default_expand_offset() == 2
    end
  end

  describe "build_query/6 plumbs :ef_search through to the knn clause" do
    test ":vector reflects the :ef_search opt in the produced query map" do
      query =
        OpenSearch.build_query_for_test(
          :vector,
          "fixture_index",
          "kw",
          [0.1, 0.2],
          [ef_search: 128],
          ["body"]
        )

      assert %Query{must: [knn_clause]} = query
      assert knn_clause["knn"]["embedding"]["method_parameters"] == %{"ef_search" => 128}
    end

    test ":hybrid reflects the :ef_search opt in the produced query map" do
      query =
        OpenSearch.build_query_for_test(
          :hybrid,
          "fixture_index",
          "kw",
          [0.1, 0.2],
          [ef_search: 64],
          ["body"]
        )

      assert %Query{must: [knn_clause]} = query
      assert knn_clause["knn"]["embedding"]["method_parameters"] == %{"ef_search" => 64}
    end

    test ":vector falls back to default_ef_search when no opt is given" do
      query =
        OpenSearch.build_query_for_test(
          :vector,
          "fixture_index",
          "kw",
          [0.1, 0.2],
          [],
          ["body"]
        )

      assert %Query{must: [knn_clause]} = query

      assert knn_clause["knn"]["embedding"]["method_parameters"] == %{
               "ef_search" => OpenSearch.default_ef_search()
             }
    end
  end

  describe "dispatch is parameterized on :gds" do
    # These tests pin the Phase 2 contract: search_chunks_with_context/5 reads
    # its target index, searchable fields, and hit-hydration logic from the
    # :gds module rather than hardcoding Cake.Books. Currently the :gds opt is
    # ignored; Phase 2 refactors the impl to route through `gds.index_name/0`,
    # `gds.search_fields/0`, and `gds.load_from_hits/1`.
    #
    # FixtureGDS records its callback invocations via Process.put so we can
    # assert dispatch without mocking OpenSearch-side traffic.

    setup do
      FixtureGDS.reset_calls()
      :ok
    end

    test "routes index_name/0 through the :gds module" do
      _ =
        try do
          OpenSearch.search_chunks_with_context(:keyword, "anything", nil, 0, gds: FixtureGDS)
        rescue
          _ -> :rescued
        catch
          _, _ -> :caught
        end

      assert :index_name in FixtureGDS.calls(),
             "expected search_chunks_with_context to call FixtureGDS.index_name/0, " <>
               "but recorded calls were #{inspect(FixtureGDS.calls())}"
    end

    test "routes search_fields/0 through the :gds module" do
      _ =
        try do
          OpenSearch.search_chunks_with_context(:keyword, "anything", nil, 0, gds: FixtureGDS)
        rescue
          _ -> :rescued
        catch
          _, _ -> :caught
        end

      assert :search_fields in FixtureGDS.calls(),
             "expected search_chunks_with_context to call FixtureGDS.search_fields/0, " <>
               "but recorded calls were #{inspect(FixtureGDS.calls())}"
    end

    test "FixtureGDS is a valid Cake.GDS" do
      behaviours = FixtureGDS.__info__(:attributes)[:behaviour] || []
      assert Cake.GDS in behaviours
      assert FixtureGDS.index_name() == "fixture_index"
      assert FixtureGDS.search_fields() == ["body"]

      hits = [%Snap.Hit{source: %{"id" => "a", "body" => "body-a"}}]
      [record] = FixtureGDS.load_from_hits(hits)
      assert record.id == "a"
      assert record.body == "body-a"
    end
  end
end
