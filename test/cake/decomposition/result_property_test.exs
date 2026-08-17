defmodule Cake.Decomposition.ResultPropertyTest do
  @moduledoc """
  Structural invariants of `Cake.Decomposition.Result.new/2` over the DAG
  representation: string inputs normalize to the degenerate flat DAG, the
  positional `question_index` stays dense and faithful, valid DAGs admit a
  topological order, the strategy enum tracks the presence of dependencies,
  and cyclic dependency graphs are rejected.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Cake.DecompositionGenerators, only: [cyclic_entries: 0, dag_entries: 0]

  alias Cake.Decomposition.Result

  property "string sub-questions normalize to a degenerate flat DAG" do
    check all(
            question <- StreamData.string(:printable, min_length: 1),
            sub_questions <- StreamData.list_of(StreamData.string(:printable))
          ) do
      result = Result.new(question, sub_questions)

      assert result.sub_questions == Enum.map(sub_questions, &%{question: &1, depends_on: []})

      case sub_questions do
        [] -> assert result.strategy == :none
        _ -> assert result.strategy == :flat
      end
    end
  end

  property "question_index keys are exactly 0..length-1 and map to positional entries" do
    check all(entries <- dag_entries()) do
      result = Result.new("q", entries)

      assert result.question_index |> Map.keys() |> Enum.sort() ==
               Enum.to_list(0..(length(entries) - 1))

      for {index, entry} <- result.question_index do
        assert Enum.at(result.sub_questions, index) == entry
      end
    end
  end

  property "valid DAG entries admit a topological order" do
    check all(entries <- dag_entries()) do
      result = Result.new("q", entries)

      order = topological_order(result.sub_questions)
      assert Enum.sort(order) == Enum.to_list(0..(length(entries) - 1))

      position = order |> Enum.with_index() |> Map.new()

      for {%{depends_on: deps}, index} <- Enum.with_index(result.sub_questions),
          dep <- deps do
        assert position[dep] < position[index]
      end
    end
  end

  property "strategy is :sequential exactly when a dependency exists" do
    check all(entries <- dag_entries()) do
      result = Result.new("q", entries)

      if Enum.any?(entries, &(&1.depends_on != [])) do
        assert result.strategy == :sequential
      else
        assert result.strategy == :flat
      end
    end
  end

  property "cyclic dependency graphs are rejected" do
    check all(entries <- cyclic_entries()) do
      assert_raise ArgumentError, fn -> Result.new("q", entries) end
    end
  end

  # Kahn's algorithm, test-side. The public ordering API lands with the
  # tier-3 resolution loop (#230); these properties only need to prove an
  # order exists.
  defp topological_order(entries) do
    entries
    |> Enum.with_index()
    |> Map.new(fn {%{depends_on: deps}, index} -> {index, MapSet.new(deps)} end)
    |> peel_ready([])
  end

  defp peel_ready(deps_by_index, order) when map_size(deps_by_index) == 0 do
    Enum.reverse(order)
  end

  defp peel_ready(deps_by_index, order) do
    {ready, blocked} =
      Enum.split_with(deps_by_index, fn {_index, deps} -> MapSet.size(deps) == 0 end)

    if ready == [] do
      flunk("dependency graph contains a cycle: #{inspect(deps_by_index)}")
    end

    ready_indices = Enum.map(ready, fn {index, _deps} -> index end)
    ready_set = MapSet.new(ready_indices)

    blocked
    |> Map.new(fn {index, deps} -> {index, MapSet.difference(deps, ready_set)} end)
    |> peel_ready(Enum.reverse(ready_indices) ++ order)
  end
end
