# User-owned LawSpec adapter for laws/prompt_drivers.lawspec.
defmodule Cake.Laws.PromptDrivers do
  @moduledoc """
  Adapts `Cake.Prompt`'s token budgets and driver protocols to the
  `cake.laws.prompt_drivers` unit: `estimate_tokens/1`, `fit_answer_pairs/2`,
  `build_with_prior_answers/5`, `self_ask_prompt/3`,
  `parse_self_ask_response/1`, `ircot_prompt/3` and
  `parse_ircot_response/1`, with `build/4` and the two driver system messages
  for the laws to compare against.

  A budget is passed as the `:max_context_tokens` option. A generated context
  becomes what `Cake.Prompt.prepare_context/2` hands on: an indexed chunk
  whose `Cake.Search.Result` carries a `Cake.Laws.FakeUnit` with that prompt
  context, numbered from 1 within its list. The contexts of each IRCoT step
  are numbered from 1 again, as each retrieval round's are.

  The translation is strict on purpose, so a shape the specification does
  not name fails the law instead of passing through: a pair that is not a
  two-tuple of binaries, a role other than the three, a message with a key
  besides `:role` and `:content`, or a parser result outside the two shapes
  each parser documents has no clause here.
  """

  alias Cake.Laws.FakeUnit
  alias Cake.Prompt
  alias Cake.Search.Provenance
  alias Cake.Search.Result
  alias LawSpec.Data.AnswerPair
  alias LawSpec.Data.Message
  alias LawSpec.Data.ReasoningStep
  alias LawSpec.Data.Retrieval

  @doc "`Prompt.estimate_tokens/1` of `text`."
  @spec estimate_tokens(binary()) :: non_neg_integer()
  def estimate_tokens(text) when is_binary(text), do: Prompt.estimate_tokens(text)

  @doc "`Prompt.fit_answer_pairs/2` of `pairs` and `budget`, as pair records."
  @spec fit_answer_pairs([LawSpec.Data.answer_pair()], non_neg_integer()) ::
          [LawSpec.Data.answer_pair()]
  def fit_answer_pairs(pairs, budget) when is_list(pairs) and is_integer(budget) do
    pairs
    |> Enum.map(&from_answer_pair/1)
    |> Prompt.fit_answer_pairs(budget)
    |> Enum.map(&to_answer_pair/1)
  end

  @doc "`Prompt.build/4` of `contexts`, `question` and `history`, with no options."
  @spec plain_prompt([binary()], binary(), [binary()]) :: [LawSpec.Data.message()]
  def plain_prompt(contexts, question, history)
      when is_list(contexts) and is_binary(question) and is_list(history) do
    contexts
    |> to_indexed_chunks()
    |> Prompt.build(question, history)
    |> Enum.map(&to_message/1)
  end

  @doc """
  `Prompt.build_with_prior_answers/5` of `contexts`, `question`, `pairs` and
  `history`, with `budget` as `:max_context_tokens`.
  """
  @spec prompt_with_prior_answers(
          [binary()],
          binary(),
          [LawSpec.Data.answer_pair()],
          [binary()],
          non_neg_integer()
        ) :: [LawSpec.Data.message()]
  def prompt_with_prior_answers(contexts, question, pairs, history, budget)
      when is_list(contexts) and is_binary(question) and is_list(pairs) and is_list(history) and
             is_integer(budget) do
    contexts
    |> to_indexed_chunks()
    |> Prompt.build_with_prior_answers(
      question,
      Enum.map(pairs, &from_answer_pair/1),
      history,
      max_context_tokens: budget
    )
    |> Enum.map(&to_message/1)
  end

  @doc """
  `Prompt.self_ask_prompt/3` of `question` and `pairs`, with `budget` as
  `:max_context_tokens`.
  """
  @spec self_ask_prompt(binary(), [LawSpec.Data.answer_pair()], non_neg_integer()) ::
          [LawSpec.Data.message()]
  def self_ask_prompt(question, pairs, budget)
      when is_binary(question) and is_list(pairs) and is_integer(budget) do
    question
    |> Prompt.self_ask_prompt(Enum.map(pairs, &from_answer_pair/1), max_context_tokens: budget)
    |> Enum.map(&to_message/1)
  end

  @doc """
  `Prompt.self_ask_system_message/0`. The argument is LawSpec's unit value: a
  LawSpec function needs an input, and the Cake function takes none.
  """
  @spec self_ask_system_message(:ok) :: binary()
  def self_ask_system_message(:ok), do: Prompt.self_ask_system_message()

  @doc "`Prompt.parse_self_ask_response/1` of `reply`, as a step record."
  @spec parse_self_ask(binary()) :: LawSpec.Data.self_ask_step()
  def parse_self_ask(reply) when is_binary(reply) do
    case Prompt.parse_self_ask_response(reply) do
      {:final, answer} when is_binary(answer) ->
        %LawSpec.Data.SelfAskStepFinalAnswer{value: answer}

      {:follow_up, question} when is_binary(question) ->
        %LawSpec.Data.SelfAskStepFollowUp{value: question}
    end
  end

  @doc """
  `Prompt.ircot_prompt/3` of `question` and `steps`, with `budget` as
  `:max_context_tokens`.
  """
  @spec ircot_prompt(binary(), [LawSpec.Data.reasoning_step()], non_neg_integer()) ::
          [LawSpec.Data.message()]
  def ircot_prompt(question, steps, budget)
      when is_binary(question) and is_list(steps) and is_integer(budget) do
    question
    |> Prompt.ircot_prompt(Enum.map(steps, &from_reasoning_step/1), max_context_tokens: budget)
    |> Enum.map(&to_message/1)
  end

  @doc "`Prompt.ircot_system_message/0`, of LawSpec's unit value."
  @spec ircot_system_message(:ok) :: binary()
  def ircot_system_message(:ok), do: Prompt.ircot_system_message()

  @doc """
  `Prompt.parse_ircot_response/1` of the map a schema-valid reply parses to:
  `reasoning` under `"reasoning"`, and `query` under `"retrieval_query"`,
  `nil` when absent.
  """
  @spec parse_ircot(binary(), :absent | {:present, binary()}) :: LawSpec.Data.ircot_verdict()
  def parse_ircot(reasoning, query) when is_binary(reasoning) do
    parsed = %{"reasoning" => reasoning, "retrieval_query" => from_maybe(query)}

    case Prompt.parse_ircot_response(parsed) do
      {:continue, step, next_query} when is_binary(step) and is_binary(next_query) ->
        %LawSpec.Data.IrcotVerdictContinues{
          value: %Retrieval{reasoning: step, query: next_query}
        }

      {:done, answer} when is_binary(answer) ->
        %LawSpec.Data.IrcotVerdictDone{value: answer}
    end
  end

  defp from_answer_pair(%AnswerPair{question: question, answer: answer}), do: {question, answer}

  defp to_answer_pair({question, answer}) when is_binary(question) and is_binary(answer) do
    %AnswerPair{question: question, answer: answer}
  end

  defp from_reasoning_step(%ReasoningStep{reasoning: reasoning, contexts: contexts}) do
    {reasoning, to_indexed_chunks(contexts)}
  end

  defp to_indexed_chunks(contexts) do
    contexts
    |> Enum.with_index(1)
    |> Enum.map(fn {context, index} -> {index, to_result(context, index)} end)
  end

  defp to_result(context, index) when is_binary(context) do
    %Result{
      retrieval_unit: %FakeUnit{
        metadata: %{id: "laws", label: "Laws", preview: "", source_ref: nil, extras: %{}},
        prompt_context: context
      },
      relevance_score: 1.0,
      prompt_index: index,
      hit_source: :search,
      index: "laws",
      provenance: %Provenance{search_type: :hybrid, query_text: "laws"}
    }
  end

  defp to_message(%{role: role, content: content} = message)
       when map_size(message) == 2 and is_binary(content) do
    %Message{role: to_role(role), content: content}
  end

  defp to_role("system"), do: %LawSpec.Data.RoleSystem{}
  defp to_role("user"), do: %LawSpec.Data.RoleUser{}
  defp to_role("assistant"), do: %LawSpec.Data.RoleAssistant{}

  defp from_maybe(:absent), do: nil
  defp from_maybe({:present, value}) when is_binary(value), do: value
end
