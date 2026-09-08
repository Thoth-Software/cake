defmodule Cake.Decomposition.Result do
  @moduledoc """
  The outcome of decomposing a question.

  `sub_questions` is a dependency DAG: each entry pairs a sub-question with
  the positional indices of the sub-questions whose answers it depends on.
  A flat decomposition is the degenerate case where every entry has
  `depends_on: []`.

  `strategy` records how the question was handled:

    - `:none` — atomic; `sub_questions` is empty.
    - `:flat` — decomposed into independent sub-questions (no entry has
      dependencies).
    - `:sequential` — at least one sub-question depends on another's
      answer; resolution must follow a topological order (the tier-3
      least-to-most loop, #230).

  `question_index` maps each sub-question's positional index to its entry,
  so a downstream `Cake.Search.Provenance` can reference a sub-question by
  index rather than by re-scanning the list. For an atomic result it is
  empty.

  `new/2` validates the dependency graph: every `depends_on` index must
  name another entry, and the graph must be acyclic. Invalid graphs raise
  `ArgumentError` — a decomposition that cannot be resolved is a
  programming (or upstream parsing) error, not a runtime condition to
  limp past.
  """

  @type strategy :: :none | :flat | :sequential

  @typedoc """
  One node of the sub-question DAG: the sub-question's text and the
  positional indices of the entries whose answers it depends on.
  """
  @type entry :: %{question: String.t(), depends_on: [non_neg_integer()]}

  @type t :: %__MODULE__{
          original_question: String.t(),
          strategy: strategy(),
          sub_questions: [entry()],
          question_index: %{non_neg_integer() => entry()}
        }

  @enforce_keys [:original_question]
  defstruct [
    :original_question,
    strategy: :none,
    sub_questions: [],
    question_index: %{}
  ]

  @doc """
  Build a `Result` from a question and its sub-questions.

  Sub-questions may be given as plain strings — each normalizes to a
  dependency-free `t:entry/0` — or as entry maps, mixed freely. With no
  sub-questions the result is atomic (`strategy: :none`). With
  dependency-free entries it is `strategy: :flat`; if any entry carries a
  dependency it is `strategy: :sequential`.

  Raises `ArgumentError` if any entry is malformed, any `depends_on` index
  is not the index of another entry, or the dependency graph contains a
  cycle.
  """
  @spec new(String.t(), [String.t() | entry()]) :: t()
  def new(original_question, sub_questions \\ [])

  def new(original_question, []) when is_binary(original_question) do
    %__MODULE__{original_question: original_question, strategy: :none}
  end

  def new(original_question, sub_questions)
      when is_binary(original_question) and is_list(sub_questions) do
    entries = Enum.map(sub_questions, &normalize_entry/1)
    validate_dependencies!(entries)

    %__MODULE__{
      original_question: original_question,
      strategy: derive_strategy(entries),
      sub_questions: entries,
      question_index: build_index(entries)
    }
  end

  defp normalize_entry(question) when is_binary(question) do
    %{question: question, depends_on: []}
  end

  defp normalize_entry(%{question: question, depends_on: depends_on})
       when is_binary(question) and is_list(depends_on) do
    %{question: question, depends_on: depends_on}
  end

  defp normalize_entry(other) do
    raise ArgumentError,
          "sub-question must be a string or a %{question: String.t(), depends_on: [index]} " <>
            "map, got: #{inspect(other)}"
  end

  defp derive_strategy(entries) do
    if Enum.all?(entries, &(&1.depends_on == [])), do: :flat, else: :sequential
  end

  defp validate_dependencies!(entries) do
    count = length(entries)

    entries
    |> Enum.with_index()
    |> Enum.each(fn {%{depends_on: deps}, index} ->
      Enum.each(deps, fn dep ->
        if not is_integer(dep) or dep < 0 or dep >= count or dep == index do
          raise ArgumentError,
                "sub-question #{index} has invalid dependency #{inspect(dep)} " <>
                  "(expected the index of another of the #{count} entries)"
        end
      end)
    end)

    if not acyclic?(entries) do
      raise ArgumentError, "sub-question dependencies form a cycle"
    end
  end

  # Kahn-style: repeatedly peel entries whose dependencies are all
  # resolved; a non-empty residue that can't be peeled is a cycle.
  defp acyclic?(entries) do
    entries
    |> Enum.with_index()
    |> Map.new(fn {%{depends_on: deps}, index} -> {index, MapSet.new(deps)} end)
    |> peel_resolvable()
  end

  defp peel_resolvable(deps_by_index) when map_size(deps_by_index) == 0, do: true

  defp peel_resolvable(deps_by_index) do
    {ready, blocked} =
      Enum.split_with(deps_by_index, fn {_index, deps} -> MapSet.size(deps) == 0 end)

    case ready do
      [] ->
        false

      _ ->
        ready_set = MapSet.new(ready, fn {index, _deps} -> index end)

        blocked
        |> Map.new(fn {index, deps} -> {index, MapSet.difference(deps, ready_set)} end)
        |> peel_resolvable()
    end
  end

  defp build_index(entries) do
    entries
    |> Enum.with_index()
    |> Map.new(fn {entry, index} -> {index, entry} end)
  end
end
