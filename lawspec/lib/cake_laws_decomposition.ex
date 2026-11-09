# User-owned LawSpec adapter for laws/decomposition.lawspec.
defmodule Cake.Laws.Decomposition do
  @moduledoc """
  Adapts `Cake.Decomposition.Result` to the `cake.laws.decomposition` unit.

  Each function translates LawSpec's generated data structs into the shapes
  `Result` takes, calls it, and translates the answer back. `Result.new/2`
  signals an invalid graph by raising `ArgumentError`; `lawspec.edn` maps
  that exception to the spec's `InvalidDecomposition` failure, so the adapter
  lets it propagate.
  """

  alias Cake.Decomposition.Result
  alias LawSpec.Data.CakeLawsDecompositionTypeEntry, as: Entry
  alias LawSpec.Data.Decomposition
  alias LawSpec.Data.KeyVal
  alias LawSpec.Data.LawspecCollectionsTypeEntry, as: KeyValEntry

  @doc "`Result.new/2` over entry maps."
  @spec decompose(binary(), [LawSpec.Data.cake_laws_decomposition_type_entry()]) ::
          LawSpec.Data.decomposition()
  def decompose(question, entries) when is_list(entries) do
    question
    |> Result.new(Enum.map(entries, &to_entry_map/1))
    |> to_decomposition()
  end

  @doc "`Result.new/2` over plain-string sub-questions."
  @spec decompose_questions(binary(), [binary()]) :: LawSpec.Data.decomposition()
  def decompose_questions(question, sub_questions) when is_list(sub_questions) do
    question
    |> Result.new(sub_questions)
    |> to_decomposition()
  end

  @doc "The indices of `Result.topological_order/1`, in order."
  @spec resolution_order(binary(), [LawSpec.Data.cake_laws_decomposition_type_entry()]) ::
          [integer()]
  def resolution_order(question, entries) when is_list(entries) do
    question
    |> Result.new(Enum.map(entries, &to_entry_map/1))
    |> Result.topological_order()
    |> Enum.map(fn {index, _entry} -> index end)
  end

  defp to_entry_map(%Entry{question: question, depends_on: depends_on}) do
    %{question: question, depends_on: depends_on}
  end

  defp from_entry_map(%{question: question, depends_on: depends_on}) do
    %Entry{question: question, depends_on: depends_on}
  end

  defp to_decomposition(%Result{} = result) do
    %Decomposition{
      strategy: to_strategy(result.strategy),
      sub_questions: Enum.map(result.sub_questions, &from_entry_map/1),
      question_index: to_key_val(result.question_index)
    }
  end

  defp to_strategy(:none), do: %LawSpec.Data.StrategyAtomic{}
  defp to_strategy(:flat), do: %LawSpec.Data.StrategyFlat{}
  defp to_strategy(:sequential), do: %LawSpec.Data.StrategySequential{}

  # LawSpec's KeyVal holds its entries in key order.
  defp to_key_val(index) when is_map(index) do
    entries =
      index
      |> Enum.sort_by(fn {key, _entry} -> key end)
      |> Enum.map(fn {key, entry} -> %KeyValEntry{key: key, value: from_entry_map(entry)} end)

    %KeyVal{value: entries}
  end
end
