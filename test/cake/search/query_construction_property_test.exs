defmodule Cake.Search.QueryConstructionPropertyTest do
  @moduledoc """
  Property tests for the query `Cake.Search.search_chunks/4` hands the
  backend, by search type.

  The backend is `Cake.Search.Backend.Mock`, which captures the `%Query{}`.
  For any type and option set: `size` follows the option; a knn clause is in
  `must` exactly when the type is not `:keyword`, carrying `k` and `ef_search`
  from the options; a multi_match clause is in `should` exactly when the type
  is not `:vector`, with boost `keyword_weight` for `:hybrid` and `1.0` for
  `:keyword`, over the fields from the options or else the GDS's own.
  `Cake.Search.Query` and its OpenSearch translation are pinned in
  `query_property_test.exs`; this file pins the dispatch table above them.
  """

  # The backend module is application config, so this module is not async.
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Mox

  alias Cake.Search
  alias Cake.Search.Backend
  alias Cake.Search.Query
  alias Cake.Support.FixtureGDS

  setup :verify_on_exit!

  setup do
    original = Application.get_env(:cake, :search_backend)
    Application.put_env(:cake, :search_backend, Backend.Mock)
    on_exit(fn -> Application.put_env(:cake, :search_backend, original) end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp search_type, do: member_of([:keyword, :vector, :hybrid])

  defp keywords, do: string(:alphanumeric, min_length: 1, max_length: 20)

  defp embedding, do: list_of(float(min: -1.0, max: 1.0), min_length: 1, max_length: 8)

  defp maybe(gen), do: one_of([constant(nil), gen])

  defp fields,
    do: list_of(string(:alphanumeric, min_length: 1, max_length: 8), min_length: 1, max_length: 3)

  # Each option is present or absent independently, so defaults are reached.
  defp opts do
    [
      size: maybe(integer(1..100)),
      k: maybe(integer(1..100)),
      ef_search: maybe(integer(1..512)),
      keyword_weight: maybe(float(min: 0.1, max: 2.0)),
      fields: maybe(fields())
    ]
    |> Enum.map(fn {key, gen} -> map(gen, &{key, &1}) end)
    |> fixed_list()
    |> map(fn pairs -> Enum.reject(pairs, fn {_key, value} -> is_nil(value) end) end)
  end

  defp capture_query(type, keywords, embedding, opts) do
    test_pid = self()

    expect(Backend.Mock, :search, fn %Query{} = query ->
      send(test_pid, {:query, query})
      {:ok, []}
    end)

    {:ok, []} = Search.search_chunks(type, keywords, embedding, [gds: FixtureGDS] ++ opts)
    assert_received {:query, %Query{} = query}
    query
  end

  defp knn_clauses(%Query{must: must}), do: Enum.filter(must, &Map.has_key?(&1, "knn"))

  defp match_clauses(%Query{should: should}),
    do: Enum.filter(should, &Map.has_key?(&1, "multi_match"))

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "the query targets the GDS's collection and takes :size from opts, else the default" do
    check all(type <- search_type(), kw <- keywords(), emb <- embedding(), opts <- opts()) do
      query = capture_query(type, kw, emb, opts)

      assert query.index == FixtureGDS.collection_name()
      assert query.size == Keyword.get(opts, :size, Search.default_size())
      assert query.filter == []
      assert query.min_score == nil
    end
  end

  property "a knn clause is in must exactly when the type is not :keyword, with k and ef_search from opts" do
    check all(type <- search_type(), kw <- keywords(), emb <- embedding(), opts <- opts()) do
      query = capture_query(type, kw, emb, opts)

      case type do
        :keyword ->
          assert query.must == []

        _vector_or_hybrid ->
          assert [%{"knn" => %{"embedding" => body}}] = knn_clauses(query)
          assert body["vector"] == emb
          assert body["k"] == Keyword.get(opts, :k, Search.default_k())

          assert body["method_parameters"] ==
                   %{"ef_search" => Keyword.get(opts, :ef_search, Search.default_ef_search())}
      end
    end
  end

  property "a multi_match clause is in should exactly when the type is not :vector, boosted by type" do
    check all(type <- search_type(), kw <- keywords(), emb <- embedding(), opts <- opts()) do
      query = capture_query(type, kw, emb, opts)

      case type do
        :vector ->
          assert query.should == []

        :keyword ->
          assert [%{"multi_match" => body}] = match_clauses(query)
          assert body["query"] == kw
          assert body["fields"] == Keyword.get(opts, :fields, FixtureGDS.search_fields())
          assert body["boost"] == 1.0

        :hybrid ->
          assert [%{"multi_match" => body}] = match_clauses(query)
          assert body["query"] == kw
          assert body["fields"] == Keyword.get(opts, :fields, FixtureGDS.search_fields())

          assert body["boost"] ==
                   Keyword.get(opts, :keyword_weight, Search.default_keyword_weight())
      end
    end
  end

  property "a keyword search needs no embedding: nil is accepted and no knn clause is built" do
    check all(kw <- keywords(), opts <- opts()) do
      query = capture_query(:keyword, kw, nil, opts)

      assert knn_clauses(query) == []
      assert [_match] = match_clauses(query)
    end
  end
end
