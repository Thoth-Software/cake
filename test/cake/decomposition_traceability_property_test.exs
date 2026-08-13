defmodule Cake.DecompositionTraceabilityPropertyTest do
  @moduledoc """
  End-to-end traceability invariants for the decomposition pipeline (#228):
  from `Cake.Decomposition.Result` through merged retrieval through
  `Cake.Responses.process/3` citations.

  These are characterization properties over the already-built tiers 1–2
  pipeline. The harness mirrors the auto-mode back half deterministically:
  per-sub-question result groups (from `Cake.DecompositionGenerators`) are
  merged with `Cake.Conversation.merge_decomposed_results/1`, indexed
  densely 1..N the way the select stage indexes context, and processed with
  arbitrary LLM response text containing valid and hallucinated `[N]`
  markers.

  Invariants:

    1. Every citation traces back to a `Search.Result` whose
       `Provenance.sub_question_index` is a valid key in the decomposition's
       `question_index` (and whose `original_query` is the original
       question).
    2. Every sub-question that contributed at least one result to the
       merged context surfaces in the processed result's `chunk_map` — no
       contributing sub-question is silently lost, even when uncited.
    3. No citation references a prompt index absent from the `chunk_map`;
       out-of-map indices surface as `:hallucinated_citation` warnings
       instead.
    4. For non-decomposed retrieval, every `Provenance` is
       `decomposed: false` with no `sub_question_index`, end to end.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Cake.DecompositionGenerators

  alias Cake.Conversation
  alias Cake.Responses
  alias Cake.Search.Result

  # The hallucinated-marker generator makes Citations.extract log its
  # expected warning hundreds of times per run; capture keeps suite output
  # readable while still printing logs for failing runs.
  @moduletag capture_log: true

  # Mirrors the select stage's dense 1..N indexing over the merged context.
  defp index_chunks(merged) do
    merged
    |> Enum.with_index(1)
    |> Enum.map(fn {result, idx} -> {idx, result} end)
  end

  defp sub_question_indices(results) do
    MapSet.new(results, fn %Result{provenance: p} -> p.sub_question_index end)
  end

  property "every citation traces to a sub-question in the decomposition's question_index" do
    check all(
            {decomposition, groups} <- decomposed_retrieval(),
            text <- response_text()
          ) do
      indexed = groups |> Conversation.merge_decomposed_results() |> index_chunks()
      by_index = Map.new(indexed)

      result = Responses.process(text, indexed, [])

      Enum.each(result.citations, fn citation ->
        %Result{provenance: provenance, retrieval_unit: unit} =
          Map.fetch!(by_index, citation.old_index)

        assert Map.has_key?(decomposition.question_index, provenance.sub_question_index)
        assert provenance.original_query == decomposition.original_question
        assert provenance.decomposed == true
        assert citation.id == Cake.Citable.metadata(unit).id
      end)
    end
  end

  property "every sub-question contributing to the merged context surfaces in the chunk_map" do
    check all(
            {_decomposition, groups} <- decomposed_retrieval(),
            text <- response_text()
          ) do
      merged = Conversation.merge_decomposed_results(groups)
      indexed = index_chunks(merged)
      by_index = Map.new(indexed)

      result = Responses.process(text, indexed, [])

      surfaced =
        result.chunk_map
        |> Map.keys()
        |> MapSet.new(fn idx -> Map.fetch!(by_index, idx).provenance.sub_question_index end)

      assert surfaced == sub_question_indices(merged)
    end
  end

  property "no citation references a prompt index absent from the chunk_map" do
    check all(
            {_decomposition, groups} <- decomposed_retrieval(),
            text <- response_text()
          ) do
      indexed = groups |> Conversation.merge_decomposed_results() |> index_chunks()

      result = Responses.process(text, indexed, [])

      Enum.each(result.citations, fn citation ->
        assert Map.has_key?(result.chunk_map, citation.old_index)
      end)

      hallucinated = for {:hallucinated_citation, idx} <- result.warnings, do: idx

      Enum.each(hallucinated, fn idx ->
        refute Map.has_key?(result.chunk_map, idx)
      end)
    end
  end

  property "non-decomposed retrieval carries decomposed: false provenance end to end" do
    check all(
            results <- plain_results(),
            text <- response_text()
          ) do
      indexed = index_chunks(results)
      by_index = Map.new(indexed)

      result = Responses.process(text, indexed, [])

      Enum.each(indexed, fn {_idx, %Result{provenance: provenance}} ->
        assert provenance.decomposed == false
        assert provenance.sub_question_index == nil
        assert provenance.original_query == nil
      end)

      Enum.each(result.citations, fn citation ->
        assert Map.has_key?(result.chunk_map, citation.old_index)

        assert citation.id ==
                 Cake.Citable.metadata(Map.fetch!(by_index, citation.old_index).retrieval_unit).id
      end)
    end
  end
end
