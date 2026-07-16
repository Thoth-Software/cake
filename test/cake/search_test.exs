defmodule Cake.SearchTest do
  use ExUnit.Case, async: false

  import Mox

  alias Cake.Search
  alias Cake.Search.Backend
  alias Cake.Search.Hit
  alias Cake.Search.Query
  alias Cake.Support.FixtureGDS

  setup :verify_on_exit!

  setup do
    original = Application.get_env(:cake, :search_backend)
    Application.put_env(:cake, :search_backend, Cake.Search.Backend.Mock)
    on_exit(fn -> Application.put_env(:cake, :search_backend, original) end)

    FixtureGDS.reset_calls()
    :ok
  end

  describe "default accessors" do
    test "default_size/0" do
      assert Search.default_size() == 30
    end

    test "default_k/0" do
      assert Search.default_k() == 30
    end

    test "default_ef_search/0" do
      assert Search.default_ef_search() == 256
    end

    test "default_keyword_weight/0" do
      assert Search.default_keyword_weight() == 0.8
    end
  end

  describe "ef_search opt" do
    test "passes ef_search through to the knn clause in vector search" do
      k = 30
      ef = 128
      vector = [0.1, 0.2, 0.3]

      query =
        "fixture_collection"
        |> Query.new(size: 30)
        |> Query.knn("embedding", vector, k, ef_search: ef)
        |> Backend.OpenSearch.to_query_map()

      [knn_clause] = query.query.bool.must
      knn_body = knn_clause["knn"]["embedding"]
      assert knn_body["ef_search"] == ef
    end

    test "build_query threads ef_search from opts into the knn clause" do
      query =
        "fixture_collection"
        |> Query.new(size: 30)
        |> Query.knn("embedding", [0.1, 0.2], 30, ef_search: 128)
        |> Query.match("test", ["body"], boost: 0.8)
        |> Backend.OpenSearch.to_query_map()

      [knn_clause | _] = query.query.bool.must
      assert knn_clause["knn"]["embedding"]["ef_search"] == 128
    end
  end

  describe "dispatch is parameterized on :gds" do
    test "routes collection_name/0 through the :gds module" do
      expect(Cake.Search.Backend.Mock, :search, fn %Query{} -> {:ok, []} end)

      Search.search_chunks(:keyword, "anything", nil, gds: FixtureGDS)

      assert :collection_name in FixtureGDS.calls()
    end

    test "routes search_fields/0 through the :gds module" do
      expect(Cake.Search.Backend.Mock, :search, fn %Query{} -> {:ok, []} end)

      Search.search_chunks(:keyword, "anything", nil, gds: FixtureGDS)

      assert :search_fields in FixtureGDS.calls()
    end

    test "routes load_from_hits/1 through the :gds module" do
      expect(Cake.Search.Backend.Mock, :search, fn %Query{} ->
        {:ok, [%Hit{id: "a", score: 1.0, source: %{"id" => "a", "body" => "hello"}}]}
      end)

      {:ok, results} =
        Search.search_chunks_with_context(:keyword, "anything", nil, 0, gds: FixtureGDS)

      assert :load_from_hits in FixtureGDS.calls()
      assert length(results) == 1
      assert hd(results).retrieval_unit.id == "a"
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
