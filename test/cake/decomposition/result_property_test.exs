defmodule Cake.Decomposition.ResultPropertyTest do
  @moduledoc """
  Structural invariants of `Cake.Decomposition.Result.new/2` over the DAG
  sub-question representation (#229).

  A `Result` holding sub-questions is always a valid DAG: every `depends_on`
  index keys into `question_index`, no dependency chain forms a cycle, and a
  topological order exists. `new/2` enforces this at construction by raising
  `ArgumentError`, so the properties cover both directions: generated valid
  DAGs (acyclic by construction, then position-shuffled so list order is not
  already topological) build results that preserve the entries, and
  corrupted DAGs — an out-of-range index, a cycle — raise.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cake.Decomposition.Result

  property "a valid DAG builds a Result preserving entries, question_index keyed 0..n-1" do
    check all(
            question <- question_text(),
            entries <- valid_dag_entries()
          ) do
      result = Result.new(question, entries)

      assert result.original_question == question
      assert result.sub_questions == entries

      expected_keys = Enum.to_list(0..(length(entries) - 1))
      assert result.question_index |> Map.keys() |> Enum.sort() == expected_keys

      # Every index maps back to the entry at that position.
      for {index, entry} <- result.question_index do
        assert Enum.at(entries, index) == entry
      end
    end
  end

  property "strategy is :flat exactly when no entry has dependencies, else :sequential" do
    check all(entries <- valid_dag_entries()) do
      result = Result.new("q", entries)

      if Enum.all?(entries, &(&1.depends_on == [])) do
        assert result.strategy == :flat
      else
        assert result.strategy == :sequential
      end
    end
  end

  property "sub_questions always admit a topological order" do
    check all(entries <- valid_dag_entries()) do
      result = Result.new("q", entries)

      assert {:ok, order} = topological_order(result.sub_questions)
      assert Enum.sort(order) == Enum.to_list(0..(length(entries) - 1))

      # Every entry is ordered after everything it depends on.
      order_position = order |> Enum.with_index() |> Map.new()

      for {entry, position} <- Enum.with_index(result.sub_questions),
          dependency <- entry.depends_on do
        assert Map.fetch!(order_position, dependency) < Map.fetch!(order_position, position)
      end
    end
  end

  property "a depends_on index outside 0..n-1 raises ArgumentError" do
    check all(
            entries <- valid_dag_entries(),
            corrupt_position <- StreamData.integer(0..(length(entries) - 1)),
            overshoot <- StreamData.integer(0..3)
          ) do
      invalid_index = length(entries) + overshoot

      corrupted =
        List.update_at(entries, corrupt_position, fn entry ->
          %{entry | depends_on: [invalid_index | entry.depends_on]}
        end)

      assert_raise ArgumentError, fn -> Result.new("q", corrupted) end
    end
  end

  property "a dependency cycle raises ArgumentError" do
    check all(questions <- StreamData.list_of(question_text(), min_length: 1, max_length: 6)) do
      count = length(questions)

      # Each entry depends on its successor, the last on the first — a full
      # cycle; a single entry degenerates to a self-dependency.
      cyclic =
        questions
        |> Enum.with_index()
        |> Enum.map(fn {question, position} ->
          %{question: question, depends_on: [rem(position + 1, count)]}
        end)

      assert_raise ArgumentError, fn -> Result.new("q", cyclic) end
    end
  end

  # --- generators ---

  defp question_text do
    StreamData.string(:printable, min_length: 1, max_length: 30)
  end

  # Valid DAG entries, acyclic by construction: each position depends only on
  # a subset of earlier positions. A random shuffle then relabels positions
  # (remapping every depends_on through the same relabeling) so the generated
  # list order is not necessarily a topological order.
  defp valid_dag_entries do
    StreamData.bind(StreamData.integer(1..6), &entries_of_size/1)
  end

  defp entries_of_size(count) do
    StreamData.bind(StreamData.fixed_list(deps_generators(count)), fn deps_lists ->
      StreamData.bind(StreamData.list_of(question_text(), length: count), fn questions ->
        StreamData.map(
          StreamData.list_of(StreamData.integer(), length: count),
          fn shuffle_keys -> shuffle_entries(questions, deps_lists, shuffle_keys) end
        )
      end)
    end)
  end

  # Each earlier position is included as a dependency or not by a boolean
  # flag — subsets without uniq_list_of's small-space retries.
  defp deps_generators(count) do
    Enum.map(0..(count - 1), fn position ->
      StreamData.map(
        StreamData.fixed_list(List.duplicate(StreamData.boolean(), position)),
        fn flags ->
          for {true, dependency} <- Enum.zip(flags, 0..(position - 1)//1), do: dependency
        end
      )
    end)
  end

  defp shuffle_entries(questions, deps_lists, shuffle_keys) do
    order =
      Enum.sort_by(0..(length(questions) - 1), fn position ->
        {Enum.at(shuffle_keys, position), position}
      end)

    new_position = order |> Enum.with_index() |> Map.new()

    Enum.map(order, fn old_position ->
      %{
        question: Enum.at(questions, old_position),
        depends_on:
          deps_lists
          |> Enum.at(old_position)
          |> Enum.map(&Map.fetch!(new_position, &1))
          |> Enum.sort()
      }
    end)
  end

  # Kahn's algorithm over entry positions; {:ok, order} lists positions in
  # dependency order, :error means no topological order exists.
  defp topological_order(entries) do
    remaining = Map.new(Enum.with_index(entries), fn {entry, position} -> {position, entry} end)
    visit(remaining, MapSet.new(), [])
  end

  defp visit(remaining, _resolved, order) when map_size(remaining) == 0 do
    {:ok, Enum.reverse(order)}
  end

  defp visit(remaining, resolved, order) do
    ready =
      Enum.find(remaining, fn {_position, entry} ->
        Enum.all?(entry.depends_on, &MapSet.member?(resolved, &1))
      end)

    case ready do
      nil ->
        :error

      {position, _entry} ->
        visit(Map.delete(remaining, position), MapSet.put(resolved, position), [position | order])
    end
  end
end
