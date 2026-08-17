defmodule Cake.DecompositionGenerators do
  @moduledoc """
  StreamData generators for decomposition-aware traceability property tests.

  Generators return `StreamData.t(value)` and compose with standard
  StreamData combinators. The central generator is `decomposed_retrieval/0`,
  which produces a `Cake.Decomposition.Result` together with the
  per-sub-question `Cake.Search.Result` groups the tier-2 pipeline would
  have retrieved for it: one group per `question_index` entry, every result
  stamped with matching decomposition provenance, and retrieval-unit IDs
  drawn from a shared pool so duplicates across sub-questions (the merge's
  dedup case) are common.

  Retrieval units are `Cake.Test.ConvoChunk` structs, so generated results
  flow through `Cake.Citable`/`Cake.Promptable` exactly like the pipeline's
  own.
  """

  alias Cake.Search.Provenance
  alias Cake.Search.Result
  alias Cake.Test.ConvoChunk

  @max_citation_index 12

  @doc "Generates non-empty printable question strings."
  @spec question() :: StreamData.t(String.t())
  def question do
    StreamData.string(:printable, min_length: 1, max_length: 40)
  end

  @doc "Generates 1..4 distinct sub-question strings."
  @spec sub_questions() :: StreamData.t([String.t()])
  def sub_questions do
    StreamData.uniq_list_of(
      StreamData.string(:printable, min_length: 1, max_length: 30),
      min_length: 1,
      max_length: 4
    )
  end

  @doc "Generates decomposed `Cake.Decomposition.Result` structs (strategy :flat)."
  @spec decomposition_result() :: StreamData.t(Cake.Decomposition.Result.t())
  def decomposition_result do
    StreamData.bind(question(), fn q ->
      StreamData.map(sub_questions(), fn subs -> Cake.Decomposition.Result.new(q, subs) end)
    end)
  end

  @doc """
  Generates `{decomposition, groups}` pairs: a decomposed
  `Cake.Decomposition.Result` plus one `Cake.Search.Result` list per
  `question_index` entry (possibly empty), each result carrying provenance
  stamped with `decomposed: true`, the decomposition's original question,
  the sub-question's text, and its index.
  """
  @spec decomposed_retrieval() ::
          StreamData.t({Cake.Decomposition.Result.t(), [[Result.t()]]})
  def decomposed_retrieval do
    StreamData.bind(decomposition_result(), fn decomposition ->
      StreamData.bind(unit_id_pool(), fn pool ->
        group_count = map_size(decomposition.question_index)

        per_group =
          StreamData.list_of(
            StreamData.tuple({StreamData.member_of(pool), relevance_score()}),
            max_length: 5
          )

        StreamData.map(
          StreamData.list_of(per_group, length: group_count),
          fn id_score_groups -> {decomposition, build_groups(decomposition, id_score_groups)} end
        )
      end)
    end)
  end

  @doc """
  Generates non-decomposed retrieval contexts: `Cake.Search.Result` lists
  with distinct retrieval-unit IDs whose provenance relies on
  `Cake.Search.Provenance` struct defaults for every decomposition field.
  """
  @spec plain_results() :: StreamData.t([Result.t()])
  def plain_results do
    StreamData.bind(unit_id_pool(), fn pool ->
      StreamData.map(
        StreamData.list_of(relevance_score(), length: length(pool)),
        fn scores ->
          pool
          |> Enum.zip(scores)
          |> Enum.map(fn {id, score} ->
            search_result(id, score, %Provenance{search_type: :hybrid, query_text: "plain"})
          end)
        end
      )
    end)
  end

  @doc """
  Generates LLM response text: words interleaved with `[N]` citation
  markers, `N` in `1..#{@max_citation_index}`. Markers beyond the indexed
  context's size exercise the hallucinated-citation path.
  """
  @spec response_text() :: StreamData.t(String.t())
  def response_text do
    segment =
      StreamData.one_of([
        StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
        StreamData.map(StreamData.integer(1..@max_citation_index), &"[#{&1}]")
      ])

    StreamData.map(StreamData.list_of(segment, max_length: 12), &Enum.join(&1, " "))
  end

  defp unit_id_pool do
    StreamData.uniq_list_of(
      StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
      min_length: 1,
      max_length: 6
    )
  end

  defp relevance_score do
    StreamData.float(min: 0.0, max: 1.0)
  end

  defp build_groups(decomposition, id_score_groups) do
    id_score_groups
    |> Enum.with_index()
    |> Enum.map(fn {id_scores, index} ->
      provenance = decomposed_provenance(decomposition, index)
      Enum.map(id_scores, fn {id, score} -> search_result(id, score, provenance) end)
    end)
  end

  defp decomposed_provenance(decomposition, index) do
    %Provenance{
      search_type: :hybrid,
      query_text: Map.fetch!(decomposition.question_index, index),
      decomposed: true,
      original_query: decomposition.original_question,
      sub_question_index: index
    }
  end

  defp search_result(id, score, provenance) do
    %Result{
      retrieval_unit: %ConvoChunk{
        embedding: [0.1, 0.2, 0.3],
        prompt_text: "chunk #{id}",
        metadata: %{id: id, label: "L-#{id}", preview: "p-#{id}", source_ref: nil, extras: %{}}
      },
      backend_score: 1.0,
      relevance_score: score,
      hit_source: :search,
      index: "test_index",
      provenance: provenance
    }
  end
end
