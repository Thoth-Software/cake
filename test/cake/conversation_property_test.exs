defmodule Cake.ConversationPropertyTest do
  @moduledoc """
  Property tests for `Cake.Conversation.apply_selection/2`.

  Pins the validation and re-indexing invariants: valid selections produce
  dense 1..N indices containing only the requested candidates, while unknown
  IDs yield an error tuple naming every unknown ID.

  Example tests live in `conversation_test.exs`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cake.Conversation
  alias Cake.Search.Provenance
  alias Cake.Search.Result
  alias Cake.Test.ConvoChunk

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
end
