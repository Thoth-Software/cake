defmodule Cake.ConversationPropertyTest do
  @moduledoc """
  Property tests for `Cake.Conversation.apply_selection/2` and
  `Cake.Conversation.merge_decomposed_results/1`.

  `apply_selection/2` pins: valid selections produce dense 1..N indices
  containing only the requested candidates, while unknown IDs yield an error
  tuple naming every unknown ID.

  `merge_decomposed_results/1` pins: merging per-sub-question result lists
  yields unique retrieval-unit IDs covering every input ID, each survivor
  carries the highest relevance score seen for its ID, decomposition
  provenance is preserved, and the output is sorted by relevance descending.

  Example tests live in `conversation_test.exs`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cake.Conversation
  alias Cake.Search.Provenance
  alias Cake.Search.Result
  alias Cake.Test.ConvoChunk

  @original_query "original question"

  defp test_provenance, do: %Provenance{search_type: :hybrid, query_text: "test"}

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp make_candidate(id) do
    %Result{
      retrieval_unit: %ConvoChunk{
        metadata: %{id: id, label: "L", preview: "p", source_ref: nil, extras: %{}}
      },
      backend_score: 1.0,
      hit_source: :search,
      index: "test_index",
      provenance: test_provenance()
    }
  end

  defp unique_id_pool do
    gen all(
          ids <-
            uniq_list_of(string(:alphanumeric, min_length: 1, max_length: 12),
              min_length: 1,
              max_length: 10
            )
        ) do
      ids
    end
  end

  defp valid_selection do
    gen all(
          all_ids <- unique_id_pool(),
          selected <- sublist_of(all_ids)
        ) do
      candidates = Enum.map(all_ids, &make_candidate/1)
      {candidates, selected}
    end
  end

  defp invalid_selection do
    gen all(
          all_ids <- unique_id_pool(),
          bogus_ids <-
            uniq_list_of(string(:alphanumeric, min_length: 1, max_length: 12),
              min_length: 1,
              max_length: 4
            )
        ) do
      candidates = Enum.map(all_ids, &make_candidate/1)
      known_set = MapSet.new(all_ids)
      truly_bogus = Enum.reject(bogus_ids, &MapSet.member?(known_set, &1))

      case truly_bogus do
        [] ->
          fresh = "BOGUS_" <> hd(all_ids)
          {candidates, [fresh]}

        _ ->
          {candidates, truly_bogus}
      end
    end
  end

  defp sublist_of(list) do
    gen all(flags <- list_of(boolean(), length: length(list))) do
      list
      |> Enum.zip(flags)
      |> Enum.filter(fn {_item, keep} -> keep end)
      |> Enum.map(fn {item, _} -> item end)
    end
  end

  defp decomposed_result(id, score, sub_question_index) do
    %Result{
      retrieval_unit: %ConvoChunk{
        metadata: %{id: id, label: "L", preview: "p", source_ref: nil, extras: %{}}
      },
      backend_score: 1.0,
      relevance_score: score,
      hit_source: :search,
      index: "test_index",
      provenance: %Provenance{
        search_type: :hybrid,
        query_text: "sub-question #{sub_question_index}",
        decomposed: true,
        original_query: @original_query,
        sub_question_index: sub_question_index
      }
    }
  end

  # One result list per sub-question, drawing unit IDs from a shared pool so
  # duplicates across (and within) sub-question searches are common.
  defp decomposed_groups do
    gen all(
          pool <-
            uniq_list_of(string(:alphanumeric, min_length: 1, max_length: 8),
              min_length: 1,
              max_length: 8
            ),
          groups <-
            list_of(
              list_of({member_of(pool), float(min: 0.0, max: 1.0)}, max_length: 6),
              min_length: 1,
              max_length: 4
            )
        ) do
      groups
      |> Enum.with_index()
      |> Enum.map(fn {pairs, index} ->
        Enum.map(pairs, fn {id, score} -> decomposed_result(id, score, index) end)
      end)
    end
  end

  defp unit_id(%Result{retrieval_unit: unit}), do: Cake.Citable.metadata(unit).id

  # Red phase: called via apply/3 so the suite compiles before the function
  # exists — a literal call would trip --warnings-as-errors.
  defp merge(groups), do: apply(Conversation, :merge_decomposed_results, [groups])

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "apply_selection/2 returns {:ok, _} for valid doc_ids" do
    check all({candidates, selected} <- valid_selection()) do
      assert {:ok, _indexed} = Conversation.apply_selection(candidates, selected)
    end
  end

  property "apply_selection/2 output has dense 1..N indices" do
    check all({candidates, selected} <- valid_selection()) do
      {:ok, indexed} = Conversation.apply_selection(candidates, selected)
      indices = Enum.map(indexed, fn {idx, _} -> idx end)
      n = length(indexed)
      expected = if n > 0, do: Enum.to_list(1..n), else: []

      assert indices == expected
    end
  end

  property "apply_selection/2 output contains only selected candidates" do
    check all({candidates, selected} <- valid_selection()) do
      {:ok, indexed} = Conversation.apply_selection(candidates, selected)
      selected_set = MapSet.new(selected)

      Enum.each(indexed, fn {_idx, result} ->
        id = Cake.Citable.metadata(result.retrieval_unit).id
        assert MapSet.member?(selected_set, id)
      end)
    end
  end

  property "apply_selection/2 returns error for unknown doc_ids" do
    check all({candidates, bogus_ids} <- invalid_selection()) do
      assert {:error, {:unknown_doc_ids, unknown}} =
               Conversation.apply_selection(candidates, bogus_ids)

      assert unknown != []

      available_set =
        MapSet.new(candidates, fn %Result{retrieval_unit: unit} ->
          Cake.Citable.metadata(unit).id
        end)

      Enum.each(unknown, fn id ->
        refute MapSet.member?(available_set, id)
      end)
    end
  end

  property "merge_decomposed_results/1 output has unique retrieval-unit IDs covering every input ID" do
    check all(groups <- decomposed_groups()) do
      merged = merge(groups)
      ids = Enum.map(merged, &unit_id/1)

      assert Enum.uniq(ids) == ids
      assert MapSet.new(ids) == MapSet.new(List.flatten(groups), &unit_id/1)
    end
  end

  property "merge_decomposed_results/1 keeps the highest relevance score per ID" do
    check all(groups <- decomposed_groups()) do
      merged = merge(groups)

      best_scores =
        groups
        |> List.flatten()
        |> Enum.group_by(&unit_id/1, & &1.relevance_score)
        |> Map.new(fn {id, scores} -> {id, Enum.max(scores)} end)

      Enum.each(merged, fn result ->
        assert result.relevance_score == best_scores[unit_id(result)]
      end)
    end
  end

  property "merge_decomposed_results/1 preserves decomposition provenance" do
    check all(groups <- decomposed_groups()) do
      Enum.each(merge(groups), fn result ->
        assert result.provenance.decomposed == true
        assert result.provenance.original_query == @original_query
        assert result.provenance.sub_question_index != nil
      end)
    end
  end

  property "merge_decomposed_results/1 sorts by relevance descending" do
    check all(groups <- decomposed_groups()) do
      scores = Enum.map(merge(groups), & &1.relevance_score)

      assert scores == Enum.sort(scores, :desc)
    end
  end
end
