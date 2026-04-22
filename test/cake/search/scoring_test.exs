defmodule Cake.Search.ScoringTest do
  use ExUnit.Case, async: true

  alias Cake.Search

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
      chunk = make_chunk("a", [1.0, 0.0])
      results = [{chunk, %{os_score: 0.5, cosine_score: 0.7, relevance_score: 0.0}}]
      [{_, %{relevance_score: score}}] = Search.normalize_and_combine(results)
      assert_in_delta score, 1.0, 1.0e-6
    end

    test "two results with os_scores — higher scores produce higher relevance" do
      chunk_a = make_chunk("a", [1.0, 0.0])
      chunk_b = make_chunk("b", [0.0, 1.0])

      results = [
        {chunk_a, %{os_score: 0.9, cosine_score: 0.8, relevance_score: 0.0}},
        {chunk_b, %{os_score: 0.4, cosine_score: 0.3, relevance_score: 0.0}}
      ]

      [{_, %{relevance_score: score_a}}, {_, %{relevance_score: score_b}}] =
        Search.normalize_and_combine(results)

      assert score_a > score_b
    end

    test "nil os_score result uses cosine only, not 0.0" do
      chunk_a = make_chunk("a", [1.0, 0.0])
      chunk_b = make_chunk("b", [0.0, 1.0])

      # chunk_b: os_score nil → relevance = normalized cosine
      # cosine_min=0.3, cosine_max=0.9 → norm_cosine_b = (0.9-0.3)/(0.9-0.3) = 1.0
      results = [
        {chunk_a, %{os_score: 0.8, cosine_score: 0.3, relevance_score: 0.0}},
        {chunk_b, %{os_score: nil, cosine_score: 0.9, relevance_score: 0.0}}
      ]

      [{_, scores_a}, {_, scores_b}] = Search.normalize_and_combine(results)

      # chunk_b's relevance is its normalized cosine (1.0), not 0.0
      assert_in_delta scores_b.relevance_score, 1.0, 1.0e-6
      # chunk_a: only one non-nil os_score → normalized to 1.0; norm_cosine = 0.0
      # relevance = 0.5 * 1.0 + 0.5 * 0.0 = 0.5
      assert_in_delta scores_a.relevance_score, 0.5, 1.0e-6
    end

    test "all identical scores normalize to 1.0" do
      chunk_a = make_chunk("a", [1.0, 0.0])
      chunk_b = make_chunk("b", [0.0, 1.0])

      results = [
        {chunk_a, %{os_score: 0.5, cosine_score: 0.5, relevance_score: 0.0}},
        {chunk_b, %{os_score: 0.5, cosine_score: 0.5, relevance_score: 0.0}}
      ]

      [{_, %{relevance_score: score_a}}, {_, %{relevance_score: score_b}}] =
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
      chunk_a = make_chunk("a", nil)
      chunk_b = make_chunk("b", nil)
      chunk_c = make_chunk("c", nil)

      results = [
        {chunk_a, %{os_score: nil, cosine_score: 0.9, relevance_score: 0.9}},
        {chunk_b, %{os_score: nil, cosine_score: 0.5, relevance_score: 0.5}},
        {chunk_c, %{os_score: nil, cosine_score: 0.1, relevance_score: 0.1}}
      ]

      filtered = Search.filter_by_threshold(results, 0.4)
      assert length(filtered) == 2
      [{_, %{relevance_score: s1}}, {_, %{relevance_score: s2}}] = filtered
      assert s1 == 0.9
      assert s2 == 0.5
    end

    test "threshold 0.0 keeps everything" do
      chunk = make_chunk("a", nil)
      results = [{chunk, %{os_score: nil, cosine_score: 0.0, relevance_score: 0.0}}]
      assert length(Search.filter_by_threshold(results, 0.0)) == 1
    end

    test "threshold 1.0 keeps only results with relevance 1.0" do
      chunk_a = make_chunk("a", nil)
      chunk_b = make_chunk("b", nil)

      results = [
        {chunk_a, %{os_score: nil, cosine_score: 1.0, relevance_score: 1.0}},
        {chunk_b, %{os_score: nil, cosine_score: 0.9, relevance_score: 0.9}}
      ]

      filtered = Search.filter_by_threshold(results, 1.0)
      assert length(filtered) == 1
      [{_, %{relevance_score: score}}] = filtered
      assert score == 1.0
    end
  end

  describe "sort_by_relevance/1" do
    test "sorts descending by relevance_score" do
      chunk_a = make_chunk("a", nil)
      chunk_b = make_chunk("b", nil)
      chunk_c = make_chunk("c", nil)

      results = [
        {chunk_b, %{os_score: nil, cosine_score: 0.5, relevance_score: 0.5}},
        {chunk_c, %{os_score: nil, cosine_score: 0.1, relevance_score: 0.1}},
        {chunk_a, %{os_score: nil, cosine_score: 0.9, relevance_score: 0.9}}
      ]

      sorted = Search.sort_by_relevance(results)
      scores = Enum.map(sorted, fn {_, %{relevance_score: s}} -> s end)
      assert scores == [0.9, 0.5, 0.1]
    end
  end

  describe "score_results/2" do
    test "attaches cosine_score and relevance_score placeholder" do
      chunk = make_chunk("a", [1.0, 0.0])
      query_embedding = [1.0, 0.0]
      results = [make_scored(chunk, 0.7)]

      [{_, scores}] = Search.score_results(results, query_embedding)

      assert_in_delta scores.cosine_score, 1.0, 1.0e-6
      assert scores.relevance_score == 0.0
      assert scores.os_score == 0.7
    end

    test "nil chunk embedding yields cosine_score 0.0" do
      chunk = make_chunk("b", nil)
      results = [make_scored(chunk, nil)]

      [{_, scores}] = Search.score_results(results, [1.0, 0.0])

      assert scores.cosine_score == 0.0
    end
  end

  describe "unzip_results/1" do
    test "returns plain chunks without scores" do
      chunk_a = make_chunk("a", [1.0, 0.0])
      chunk_b = make_chunk("b", [0.0, 1.0])

      results = [
        {chunk_a, %{os_score: 0.8, cosine_score: 0.9, relevance_score: 0.85}},
        {chunk_b, %{os_score: nil, cosine_score: 0.5, relevance_score: 0.5}}
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

  defp make_scored(chunk, os_score) do
    {chunk, %{os_score: os_score}}
  end
end
