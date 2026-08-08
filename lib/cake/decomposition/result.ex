defmodule Cake.Decomposition.Result do
  @moduledoc """
  The outcome of decomposing a question.

  `strategy` records how the question was handled:

    - `:none` — atomic; `sub_questions` is empty.
    - `:flat` — decomposed into an unordered list of independent sub-questions.

  `question_index` maps each sub-question's positional index to its text, so a
  downstream `Cake.Search.Provenance` can reference a sub-question by index
  rather than by re-scanning the list. For an atomic result it is empty.

  (Tier 3 of the Query Decomposition epic replaces the flat `sub_questions`
  list with a DAG representation and adds the `:sequential` strategy; until
  then the enum is deliberately `:none | :flat`.)
  """

  @type strategy :: :none | :flat

  @type t :: %__MODULE__{
          original_question: String.t(),
          strategy: strategy(),
          sub_questions: [String.t()],
          question_index: %{non_neg_integer() => String.t()}
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

  With no sub-questions the result is atomic (`strategy: :none`, empty
  `sub_questions` and `question_index`). With sub-questions it is
  `strategy: :flat`, and `question_index` maps `0..length-1` to each
  sub-question's text.
  """
  @spec new(String.t(), [String.t()]) :: t()
  def new(original_question, sub_questions \\ [])

  # Placeholder: always produces an atomic result. Replaced by the real
  # constructor once the tests that pin its behaviour are in place.
  def new(original_question, _sub_questions) when is_binary(original_question) do
    %__MODULE__{original_question: original_question, strategy: :none}
  end
end
