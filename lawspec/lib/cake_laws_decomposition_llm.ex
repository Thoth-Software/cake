# User-owned LawSpec adapter for laws/decomposition_llm.lawspec.
defmodule Cake.Laws.DecompositionLlm do
  @moduledoc """
  Adapts `Cake.Decomposition.LLM.decompose/2` to the
  `cake.laws.decomposition_llm` unit.

  `llm_decompose/3` is the first adapter here that `uses Generation`: LawSpec
  hands it the handler the law runs under, before its own arguments.
  `decompose/2` takes its generation collaborator as a module, so the adapter
  installs the handler behind `Cake.Laws.HandlerGeneration` and passes that
  module as `:generation`. It repairs nothing: a `Result` is translated field
  for field (`Cake.Laws.Decomposition.to_decomposition/1`) and a failure
  reason by reason, and an exception from `decompose/2` propagates, so a law
  that reaches one fails.

  The other two adapters are what the laws compare against: `Result.new/2`,
  whose own laws are the pilot unit's, and
  `Cake.Prompt.decomposition_prompt/1`.
  """

  alias Cake.Decomposition.LLM
  alias Cake.Laws.HandlerGeneration
  alias LawSpec.Abilities.Cake.Laws.Generation.Generation
  alias LawSpec.Data

  @doc """
  `LLM.decompose/2` of the question, with the handler as its `:generation`
  module. `{:present, model}` is passed as `:model`; with `:absent` the
  option is left out, so `decompose/2` uses its default.
  """
  @spec llm_decompose(Generation.t(), binary(), :absent | {:present, binary()}) ::
          {:left, Data.decomposition_error()} | {:right, Data.decomposition()}
  def llm_decompose(%Generation{} = generation_handler, question, model) do
    opts = [generation: HandlerGeneration] ++ model_opt(model)

    generation_handler
    |> HandlerGeneration.with_handler(fn -> LLM.decompose(question, opts) end)
    |> to_either()
  end

  @doc "`Cake.Decomposition.Result.new/2` over plain-string sub-questions."
  @spec result_new(binary(), [binary()]) :: Data.decomposition()
  def result_new(question, sub_questions) when is_list(sub_questions) do
    Cake.Laws.Decomposition.decompose_questions(question, sub_questions)
  end

  @doc "`Cake.Prompt.decomposition_prompt/1` of the question, as LawSpec's messages."
  @spec decomposition_prompt(binary()) :: [Data.message()]
  def decomposition_prompt(question) do
    question
    |> Cake.Prompt.decomposition_prompt()
    |> HandlerGeneration.to_messages()
  end

  defp model_opt(:absent), do: []
  defp model_opt({:present, model}), do: [model: model]

  defp to_either({:ok, result}), do: {:right, Cake.Laws.Decomposition.to_decomposition(result)}

  defp to_either({:error, {:invalid_response, description}}),
    do: {:left, %Data.DecompositionErrorInvalidResponse{value: description}}

  defp to_either({:error, {:generation, reason}}) do
    failure = Cake.Laws.Generation.to_error(reason)
    {:left, %Data.DecompositionErrorGenerationFailed{value: failure}}
  end
end
