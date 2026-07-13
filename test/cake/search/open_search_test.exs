defmodule Cake.Search.OpenSearchTest do
  use ExUnit.Case, async: false

  alias Cake.Search.Backends
  alias Cake.Search.Hit
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
  end

  describe "ef_search opt" do
    test "passes ef_search through to the knn clause in vector search" do
      alias Cake.Search.Query

      k = 30
      ef = 128
      vector = [0.1, 0.2, 0.3]

      query =
        "fixture_collection"
        |> Query.new(size: 30)
        |> Query.knn("embedding", vector, k, ef_search: ef)
        |> Backends.OpenSearch.to_query_map()

      [knn_clause] = query.query.bool.must
      knn_body = knn_clause["knn"]["embedding"]
      assert knn_body["ef_search"] == ef
    end

    test "build_query threads ef_search from opts into the knn clause" do
      alias Cake.Search.Query

      query =
        "fixture_collection"
        |> Query.new(size: 30)
        |> Query.knn("embedding", [0.1, 0.2], 30, ef_search: 128)
        |> Query.match("test", ["body"], boost: 0.8)
        |> Backends.OpenSearch.to_query_map()

      [knn_clause | _] = query.query.bool.must
      assert knn_clause["knn"]["embedding"]["ef_search"] == 128
    end
  end

  describe "dispatch is parameterized on :gds" do
    setup do
      FixtureGDS.reset_calls()
      :ok
    end

    test "routes collection_name/0 through the :gds module" do
      _ =
        try do
          OpenSearch.search_chunks_with_context(:keyword, "anything", nil, 0, gds: FixtureGDS)
        rescue
          _ -> :rescued
        catch
          _, _ -> :caught
        end

      assert :collection_name in FixtureGDS.calls(),
             "expected search_chunks_with_context to call FixtureGDS.collection_name/0, " <>
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
      assert FixtureGDS.collection_name() == "fixture_collection"
      assert FixtureGDS.search_fields() == ["body"]

      hits = [%Hit{id: "a", source: %{"id" => "a", "body" => "body-a"}}]
      [record] = FixtureGDS.load_from_hits(hits)
      assert record.id == "a"
      assert record.body == "body-a"
    end
  end
end
