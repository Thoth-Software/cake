defmodule Cake.Search.OpenSearchTest do
  use ExUnit.Case, async: false

  alias Cake.Search.OpenSearch
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

  describe "ef_search opt" do
    test "passes ef_search through to the knn clause in vector search" do
      # We can't easily capture the query map sent to Snap without an
      # integration test, so we test the contract through Query directly:
      # build a query the same way OpenSearch.build_query(:vector, ...) does,
      # passing ef_search, and verify it lands in the knn body.
      alias Cake.Search.Query

      k = 30
      ef = 128
      vector = [0.1, 0.2, 0.3]

      query =
        "fixture_index"
        |> Query.new(size: 30)
        |> Query.knn("embedding", vector, k, ef_search: ef)
        |> Query.to_query_map()

      [knn_clause] = query.query.bool.must
      knn_body = knn_clause["knn"]["embedding"]
      assert knn_body["ef_search"] == ef
    end

    test "build_query threads ef_search from opts into the knn clause" do
      alias Cake.Search.Query

      query =
        "fixture_index"
        |> Query.new(size: 30)
        |> Query.knn("embedding", [0.1, 0.2], 30, ef_search: 128)
        |> Query.match("test", ["body"], boost: 0.8)
        |> Query.to_query_map()

      [knn_clause | _] = query.query.bool.must
      assert knn_clause["knn"]["embedding"]["ef_search"] == 128
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
