defmodule Cake.Search.ScoringTest do
  use ExUnit.Case, async: true

  alias Cake.Search
  alias Cake.Search.Provenance
  alias Cake.Search.Result

  describe "cosine_similarity/2" do
    test "identical vectors return 1.0" do
      assert_in_delta Search.cosine_similarity([1.0, 0.0, 0.0], [1.0, 0.0, 0.0]), 1.0, 1.0e-6
    end

    test "orthogonal vectors return 0.0" do
      assert_in_delta Search.cosine_similarity([1.0, 0.0], [0.0, 1.0]), 0.0, 1.0e-6
    end

    test "opposite vectors return -1.0" do
      assert_in_delta Search.cosine_similarity([1.0, 0.0], [-1.0, 0.0]), -1.0, 1.0e-6
    end

    test "commutative" do
      a = [1.0, 2.0, 3.0]
      b = [4.0, 5.0, 6.0]
      assert_in_delta Search.cosine_similarity(a, b), Search.cosine_similarity(b, a), 1.0e-6
    end

    test "zero vector returns 0.0" do
      assert Search.cosine_similarity([0.0, 0.0], [1.0, 2.0]) == 0.0
    end

    test "non-trivial case is approximately 0.9746" do
      # dot = 1*4 + 2*5 + 3*6 = 32, mag_a = sqrt(14), mag_b = sqrt(77)
      # result = 32 / sqrt(1078)
      expected = 32.0 / :math.sqrt(1078.0)
      assert_in_delta Search.cosine_similarity([1.0, 2.0, 3.0], [4.0, 5.0, 6.0]), expected, 1.0e-6
    end
  end

  describe "normalize_and_combine/1" do
    test "single result normalizes to 1.0" do
      results = [make_result("a", [1.0, 0.0], backend_score: 0.5, cosine_score: 0.7)]
      [%Result{relevance_score: score}] = Search.normalize_and_combine(results)
      assert_in_delta score, 1.0, 1.0e-6
    end

    test "two results with backend_scores — higher scores produce higher relevance" do
      results = [
        make_result("a", [1.0, 0.0], backend_score: 0.9, cosine_score: 0.8),
        make_result("b", [0.0, 1.0], backend_score: 0.4, cosine_score: 0.3)
      ]

      [%Result{relevance_score: score_a}, %Result{relevance_score: score_b}] =
        Search.normalize_and_combine(results)

      assert score_a > score_b
    end

    test "nil backend_score result uses cosine only, not 0.0" do
      # chunk_b: backend_score nil → relevance = normalized cosine
      # cosine_min=0.3, cosine_max=0.9 → norm_cosine_b = (0.9-0.3)/(0.9-0.3) = 1.0
      results = [
        make_result("a", [1.0, 0.0], backend_score: 0.8, cosine_score: 0.3),
        make_result("b", [0.0, 1.0],
          backend_score: nil,
          cosine_score: 0.9,
          hit_source: :expansion
        )
      ]

      [%Result{relevance_score: relevance_a}, %Result{relevance_score: relevance_b}] =
        Search.normalize_and_combine(results)

      # chunk_b's relevance is its normalized cosine (1.0), not 0.0
      assert_in_delta relevance_b, 1.0, 1.0e-6
      # chunk_a: only one non-nil backend_score → normalized to 1.0; norm_cosine = 0.0
      # relevance = 0.5 * 1.0 + 0.5 * 0.0 = 0.5
      assert_in_delta relevance_a, 0.5, 1.0e-6
    end

    test "all identical scores normalize to 1.0" do
      results = [
        make_result("a", [1.0, 0.0], backend_score: 0.5, cosine_score: 0.5),
        make_result("b", [0.0, 1.0], backend_score: 0.5, cosine_score: 0.5)
      ]

      [%Result{relevance_score: score_a}, %Result{relevance_score: score_b}] =
        Search.normalize_and_combine(results)

      assert_in_delta score_a, 1.0, 1.0e-6
      assert_in_delta score_b, 1.0, 1.0e-6
    end

    test "empty list returns empty list" do
      assert Search.normalize_and_combine([]) == []
    end
  end

  describe "filter_by_threshold/2" do
    test "filters results below threshold" do
      results = [
        make_result("a", nil, backend_score: nil, cosine_score: 0.9, relevance_score: 0.9),
        make_result("b", nil, backend_score: nil, cosine_score: 0.5, relevance_score: 0.5),
        make_result("c", nil, backend_score: nil, cosine_score: 0.1, relevance_score: 0.1)
      ]

      filtered = Search.filter_by_threshold(results, 0.4)
      assert length(filtered) == 2
      [%Result{relevance_score: s1}, %Result{relevance_score: s2}] = filtered
      assert s1 == 0.9
      assert s2 == 0.5
    end

    test "threshold 0.0 keeps everything" do
      results = [
        make_result("a", nil, backend_score: nil, cosine_score: 0.0, relevance_score: 0.0)
      ]

      assert length(Search.filter_by_threshold(results, 0.0)) == 1
    end

    test "threshold 1.0 keeps only results with relevance 1.0" do
      results = [
        make_result("a", nil, backend_score: nil, cosine_score: 1.0, relevance_score: 1.0),
        make_result("b", nil, backend_score: nil, cosine_score: 0.9, relevance_score: 0.9)
      ]

      filtered = Search.filter_by_threshold(results, 1.0)
      assert length(filtered) == 1
      [%Result{relevance_score: score}] = filtered
      assert score == 1.0
    end
  end

  describe "sort_by_relevance/1" do
    test "sorts descending by relevance_score" do
      results = [
        make_result("b", nil, backend_score: nil, cosine_score: 0.5, relevance_score: 0.5),
        make_result("c", nil, backend_score: nil, cosine_score: 0.1, relevance_score: 0.1),
        make_result("a", nil, backend_score: nil, cosine_score: 0.9, relevance_score: 0.9)
      ]

      sorted = Search.sort_by_relevance(results)
      scores = Enum.map(sorted, & &1.relevance_score)
      assert scores == [0.9, 0.5, 0.1]
    end
  end

  describe "score_results/2" do
    test "populates cosine_score from query embedding" do
      query_embedding = [1.0, 0.0]
      results = [make_result("a", [1.0, 0.0], backend_score: 0.7)]

      [%Result{cosine_score: cosine, backend_score: backend}] =
        Search.score_results(results, query_embedding)

      assert_in_delta cosine, 1.0, 1.0e-6
      assert backend == 0.7
    end

    test "nil chunk embedding yields cosine_score 0.0" do
      results = [make_result("b", nil, backend_score: nil, hit_source: :expansion)]

      [%Result{cosine_score: cosine}] = Search.score_results(results, [1.0, 0.0])

      assert cosine == 0.0
    end
  end

  describe "unzip_results/1" do
    test "returns plain chunks without scores" do
      chunk_a = make_chunk("a", [1.0, 0.0])
      chunk_b = make_chunk("b", [0.0, 1.0])

      results = [
        wrap(chunk_a, backend_score: 0.8, cosine_score: 0.9, relevance_score: 0.85),
        wrap(chunk_b,
          backend_score: nil,
          cosine_score: 0.5,
          relevance_score: 0.5,
          hit_source: :expansion
        )
      ]

      assert Search.unzip_results(results) == [chunk_a, chunk_b]
    end
  end

  defp make_chunk(id, embedding) do
    %Cake.Books.Chunk{
      id: id,
      text: "test chunk #{id}",
      embedding: embedding,
      chunk_index: 0,
      word_count: 2,
      char_count: 10,
      parsed_book_id: Ecto.UUID.generate()
    }
  end

  defp test_provenance, do: %Provenance{search_type: :hybrid, query_text: "test"}

  defp make_result(id, embedding, opts) do
    id |> make_chunk(embedding) |> wrap(opts)
  end

  defp wrap(unit, opts) do
    %Result{
      retrieval_unit: unit,
      backend_score: Keyword.get(opts, :backend_score),
      cosine_score: Keyword.get(opts, :cosine_score),
      relevance_score: Keyword.get(opts, :relevance_score),
      hit_source: Keyword.get(opts, :hit_source, :search),
      index: "test_index",
      provenance: test_provenance()
    }
  end
end
