defmodule Cake.Prompt.IRCoTLiveTest do
  @moduledoc """
  The IRCoT structured-step protocol against the production model (#247,
  item 15).

  `Cake.Conversation`'s IRCoT loop asks for one reasoning step per round
  as JSON constrained by `Cake.Prompt.ircot_schema/0`, and ends when the
  model sets `"retrieval_query"` to null. The provider enforces the
  schema, so the shape risk is low; whether the model ever emits the null
  terminator — rather than running to the iteration cap every time — is
  only observable live. This suite drives the protocol directly through
  `Cake.Prompt.ircot_prompt/3` and `Cake.Generation.OpenAI.complete_json/3`,
  retrieval-free: a step's retrieval query is acknowledged with an empty
  context (rendered as "(nothing relevant retrieved)") and the step folds
  into the next driver prompt the way the loop folds a retrieved one. Full
  interleaved turns through `Conversation` belong to #271.

  Invariants only: every step validates against the schema and classifies
  through `Cake.Prompt.parse_ircot_response/1`; a trivially answerable
  question terminates with a null `retrieval_query` within the production
  iteration cap. Reasoning text is never asserted.
  """

  use Cake.LiveLLMCase

  alias Cake.Generation.OpenAI
  alias Cake.Prompt

  @question "What is the capital city of France?"

  defp model, do: production_response_model()

  defp max_iterations, do: Application.get_env(:cake, :max_ircot_iterations, 5)

  test "every step validates and classifies, and a trivial question ends with a null retrieval_query within the cap" do
    {steps, outcome} = drive(@question, [], max_iterations(), [])

    assert steps != []

    for parsed <- steps do
      assert ExJsonSchema.Validator.valid?(Prompt.ircot_schema(), parsed)
      assert parsed |> Map.keys() |> Enum.sort() == ["reasoning", "retrieval_query"]
      assert String.trim(parsed["reasoning"]) != ""
    end

    assert {:done, terminating_step, answer} = outcome
    assert is_nil(terminating_step["retrieval_query"])
    assert String.trim(answer) != ""
  end

  # Mirrors Cake.Conversation.ircot_round/5's accounting: at most `cap`
  # reasoning generations; a continuing step folds into the next prompt
  # oldest-first with nothing retrieved (accumulated newest-first, reversed
  # on use); the cap spent with no terminator is :exhausted.
  defp drive(_question, _steps_rev, 0, parsed_rev), do: {Enum.reverse(parsed_rev), :exhausted}

  defp drive(question, steps_rev, rounds_left, parsed_rev) do
    messages = Prompt.ircot_prompt(question, Enum.reverse(steps_rev))

    assert {:ok, %{parsed: parsed}} =
             OpenAI.complete_json(messages, model(), schema: Prompt.ircot_schema())

    case Prompt.parse_ircot_response(parsed) do
      {:done, reasoning} ->
        {Enum.reverse([parsed | parsed_rev]), {:done, parsed, reasoning}}

      {:continue, reasoning, _query} ->
        drive(question, [{reasoning, []} | steps_rev], rounds_left - 1, [parsed | parsed_rev])
    end
  end
end
