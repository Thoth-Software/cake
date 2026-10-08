defmodule Cake.Search.ResultBuildingPropertyTest do
  @moduledoc """
  Property tests for how `Cake.Search.search_chunks_with_context/5` turns
  backend hits into `Cake.Search.Result` structs.

  With `Cake.Support.ExpandingGDS` (a corpus of ordered records and a real
  neighbour expansion): every hit's unit comes back as a direct hit carrying
  its backend score; every neighbour the expansion adds comes back as an
  expansion with no backend score; nothing else appears; every result names
  the GDS's collection and shares one provenance built from the search type
  and the query text. With `Cake.Support.FixtureGDS` (identity expansion)
  no expansion result appears at all.
  """

  # The backend module is application config, so this module is not async.
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Mox

  alias Cake.Search
  alias Cake.Search.Backend
  alias Cake.Search.Hit
  alias Cake.Search.Provenance
  alias Cake.Search.Result
  alias Cake.Support.ExpandingGDS
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

  # A corpus of 1..8 ordered records and the hits as a flag per record with a
  # score each.
  defp corpus_and_hits do
    gen all(
          size <- integer(1..8),
          flags <- list_of(boolean(), length: size),
          scores <- list_of(float(min: 0.0, max: 10.0), length: size)
        ) do
      {Enum.map(0..(size - 1), &ExpandingGDS.record/1), hits_for(flags, scores)}
    end
  end

  defp retrieval_case do
    gen all(
          {corpus, hits} <- corpus_and_hits(),
          offset <- integer(0..3),
          type <- search_type(),
          query_text <- string(:alphanumeric, min_length: 1, max_length: 12)
        ) do
      %{corpus: corpus, hits: hits, offset: offset, type: type, query_text: query_text}
    end
  end

  # One hit per flagged ordinal, shuffled so nothing leans on hit order.
  defp hits_for(flags, scores) do
    flags
    |> Enum.zip(scores)
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{true, score}, ordinal} ->
        [%Hit{id: "r#{ordinal}", score: score, source: %{"id" => "r#{ordinal}"}}]

      {{false, _score}, _ordinal} ->
        []
    end)
    |> Enum.shuffle()
  end

  defp search!(gds, %{hits: hits, offset: offset, type: type, query_text: query_text}) do
    expect(Backend.Mock, :search, fn _query -> {:ok, hits} end)

    {:ok, results} =
      Search.search_chunks_with_context(type, query_text, [0.5, 0.5], offset, gds: gds)

    results
  end

  defp ids(results), do: results |> Enum.map(& &1.retrieval_unit.id) |> Enum.sort()

  defp hit_ids(hits), do: hits |> Enum.map(& &1.id) |> Enum.sort()

  defp neighbour_ids(%{corpus: corpus, hits: hits, offset: offset}) do
    hit_ordinals = for %Hit{id: "r" <> n} <- hits, do: String.to_integer(n)

    corpus
    |> Enum.filter(fn record -> Enum.any?(hit_ordinals, &(abs(&1 - record.ordinal) <= offset)) end)
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "every hit's unit is a :search result carrying that hit's backend score" do
    check all(case <- retrieval_case()) do
      ExpandingGDS.put_corpus(case.corpus)
      results = search!(ExpandingGDS, case)

      direct = Enum.filter(results, &(&1.hit_source == :search))

      assert ids(direct) == hit_ids(case.hits)

      for %Result{retrieval_unit: unit, backend_score: score} <- direct do
        assert score == Enum.find(case.hits, &(&1.id == unit.id)).score
      end
    end
  end

  property "every neighbour the expansion adds is an :expansion result with no backend score, and nothing else appears" do
    check all(case <- retrieval_case()) do
      ExpandingGDS.put_corpus(case.corpus)
      results = search!(ExpandingGDS, case)

      expansions = Enum.filter(results, &(&1.hit_source == :expansion))

      assert ids(expansions) == neighbour_ids(case) -- hit_ids(case.hits)
      assert Enum.all?(expansions, &is_nil(&1.backend_score))
      assert ids(results) == neighbour_ids(case)
    end
  end

  property "every result names the GDS's collection and shares one provenance from the search type and query text" do
    check all(case <- retrieval_case()) do
      ExpandingGDS.put_corpus(case.corpus)
      results = search!(ExpandingGDS, case)

      expected = %Provenance{search_type: case.type, query_text: case.query_text}

      for %Result{} = result <- results do
        assert result.index == ExpandingGDS.collection_name()
        assert result.provenance == expected

        assert result.cosine_score == nil and result.relevance_score == nil and
                 result.prompt_index == nil
      end
    end
  end

  property "with an identity expansion (FixtureGDS) the results are exactly the hits and none is an :expansion" do
    check all(case <- retrieval_case()) do
      results = search!(FixtureGDS, case)

      assert ids(results) == hit_ids(case.hits)
      assert Enum.all?(results, &(&1.hit_source == :search))
    end
  end
end
