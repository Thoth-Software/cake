defmodule Cake.Search.ScoringPropertyTest do
  @moduledoc """
  Property tests for `Cake.Search` scoring utilities: `cosine_similarity/2`
  and `normalize_and_combine/1`.

  Pins mathematical invariants (symmetry, range, self-similarity, scalar
  invariance) and normalization invariants (output range, length preservation)
  that hold for arbitrary inputs.

  Example tests live in `search/scoring_test.exs`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cake.Search
  alias Cake.Search.Provenance
  alias Cake.Search.Result
  alias Cake.Test.ConvoChunk

  @epsilon 1.0e-9

  defp test_provenance, do: %Provenance{search_type: :hybrid, query_text: "test"}

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp dimension, do: integer(1..16)

  defp float_vector(dim) do
    list_of(float(min: -100.0, max: 100.0), length: dim)
  end

  defp non_zero_vector(dim) do
    StreamData.filter(float_vector(dim), fn vec -> Enum.any?(vec, &(&1 != 0.0)) end)
  end

  defp positive_scalar do
    float(min: 0.01, max: 100.0)
  end

  defp scored_result do
    gen all(
          id <- string(:alphanumeric, min_length: 1, max_length: 8),
          backend_score <- one_of([constant(nil), float(min: 0.0, max: 10.0)]),
          cosine_score <- float(min: -1.0, max: 1.0),
          hit_source <- member_of([:search, :expansion])
        ) do
      %Result{
        retrieval_unit: %ConvoChunk{
          metadata: %{id: id, label: "L", preview: "p", source_ref: nil, extras: %{}}
        },
        backend_score: backend_score,
        cosine_score: cosine_score,
        hit_source: hit_source,
        index: "test_index",
        provenance: test_provenance()
      }
    end
  end

  # ---------------------------------------------------------------------------
  # cosine_similarity/2 properties
  # ---------------------------------------------------------------------------

  property "cosine_similarity is symmetric" do
    check all(
            dim <- dimension(),
            a <- float_vector(dim),
            b <- float_vector(dim)
          ) do
      assert_in_delta Search.cosine_similarity(a, b),
                      Search.cosine_similarity(b, a),
                      @epsilon
    end
  end

  property "cosine_similarity result is in [-1.0, 1.0]" do
    check all(
            dim <- dimension(),
            a <- non_zero_vector(dim),
            b <- non_zero_vector(dim)
          ) do
      sim = Search.cosine_similarity(a, b)
      assert sim >= -1.0 - @epsilon
      assert sim <= 1.0 + @epsilon
    end
  end

  property "cosine_similarity of a non-zero vector with itself is 1.0" do
    check all(
            dim <- dimension(),
            v <- non_zero_vector(dim)
          ) do
      assert_in_delta Search.cosine_similarity(v, v), 1.0, @epsilon
    end
  end

  property "cosine_similarity returns 0.0 when either vector is zero" do
    check all(
            dim <- dimension(),
            v <- float_vector(dim)
          ) do
      zero = List.duplicate(0.0, dim)
      assert Search.cosine_similarity(zero, v) == 0.0
      assert Search.cosine_similarity(v, zero) == 0.0
    end
  end

  property "positive scalar multiplication does not change cosine_similarity" do
    check all(
            dim <- dimension(),
            a <- non_zero_vector(dim),
            b <- non_zero_vector(dim),
            k <- positive_scalar()
          ) do
      scaled = Enum.map(a, &(&1 * k))

      assert_in_delta Search.cosine_similarity(scaled, b),
                      Search.cosine_similarity(a, b),
                      1.0e-6
    end
  end

  # ---------------------------------------------------------------------------
  # normalize_and_combine/1 properties
  # ---------------------------------------------------------------------------

  property "normalize_and_combine/1 relevance_score is always in [0.0, 1.0]" do
    check all(results <- list_of(scored_result(), min_length: 1, max_length: 10)) do
      combined = Search.normalize_and_combine(results)

      Enum.each(combined, fn %Result{relevance_score: score} ->
        assert score >= 0.0 - @epsilon
        assert score <= 1.0 + @epsilon
      end)
    end
  end

  property "normalize_and_combine/1 preserves list length" do
    check all(results <- list_of(scored_result(), min_length: 1, max_length: 10)) do
      assert length(Search.normalize_and_combine(results)) == length(results)
    end
  end

  property "normalize_and_combine/1 on a single result yields relevance 1.0" do
    check all(result <- scored_result()) do
      [%Result{relevance_score: score}] = Search.normalize_and_combine([result])
      assert_in_delta score, 1.0, @epsilon
    end
  end
end
