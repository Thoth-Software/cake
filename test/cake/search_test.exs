defmodule Cake.SearchTest do
  use ExUnit.Case, async: false

  import Mox

  alias Cake.Search
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

  defp knn_clauses(%Query{must: must}), do: Enum.filter(must, &Map.has_key?(&1, "knn"))

  defp match_clauses(%Query{should: should}),
    do: Enum.filter(should, &Map.has_key?(&1, "multi_match"))

  defp capture_query do
    test_pid = self()

    expect(Cake.Search.Backend.Mock, :search, fn %Query{} = query ->
      send(test_pid, {:query, query})
      {:ok, []}
    end)

    fn -> assert_received({:query, %Query{} = query}) && query end
  end

  describe "the search type is an opt defaulting to :hybrid" do
    test "search_chunks/3 called without :search_type builds a hybrid query" do
      captured = capture_query()

      assert {:ok, []} = Search.search_chunks("anything", [0.1, 0.2], gds: FixtureGDS)

      query = captured.()
      assert [%{"knn" => %{"embedding" => %{"vector" => [0.1, 0.2]}}}] = knn_clauses(query)
      assert [%{"multi_match" => %{"query" => "anything"}}] = match_clauses(query)
    end

    test "search_chunks_with_context/4 called without :search_type builds a hybrid query and stamps hybrid provenance" do
      captured = capture_query()

      assert {:ok, []} =
               Search.search_chunks_with_context("anything", [0.1, 0.2], 0, gds: FixtureGDS)

      query = captured.()
      assert [%{"knn" => _}] = knn_clauses(query)
      assert [%{"multi_match" => _}] = match_clauses(query)

      expect(Cake.Search.Backend.Mock, :search, fn %Query{} ->
        {:ok, [%Hit{id: "a", score: 1.0, source: %{"id" => "a", "body" => "hello"}}]}
      end)

      assert {:ok, [result]} =
               Search.search_chunks_with_context("anything", [0.1, 0.2], 0, gds: FixtureGDS)

      assert result.provenance.search_type == :hybrid
    end

    test "search_type: :keyword in opts builds a keyword-only query and needs no embedding" do
      captured = capture_query()

      assert {:ok, []} =
               Search.search_chunks("anything", nil, gds: FixtureGDS, search_type: :keyword)

      query = captured.()
      assert knn_clauses(query) == []
      assert [%{"multi_match" => %{"query" => "anything"}}] = match_clauses(query)
    end
  end

  describe "dispatch is parameterized on :gds" do
    test "routes collection_name/0 through the :gds module" do
      expect(Cake.Search.Backend.Mock, :search, fn %Query{} -> {:ok, []} end)

      Search.search_chunks("anything", nil, gds: FixtureGDS, search_type: :keyword)

      assert :collection_name in FixtureGDS.calls()
    end

    test "routes search_fields/0 through the :gds module" do
      expect(Cake.Search.Backend.Mock, :search, fn %Query{} -> {:ok, []} end)

      Search.search_chunks("anything", nil, gds: FixtureGDS, search_type: :keyword)

      assert :search_fields in FixtureGDS.calls()
    end

    test "routes load_from_hits/1 through the :gds module" do
      expect(Cake.Search.Backend.Mock, :search, fn %Query{} ->
        {:ok, [%Hit{id: "a", score: 1.0, source: %{"id" => "a", "body" => "hello"}}]}
      end)

      {:ok, results} =
        Search.search_chunks_with_context("anything", nil, 0,
          gds: FixtureGDS,
          search_type: :keyword
        )

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
