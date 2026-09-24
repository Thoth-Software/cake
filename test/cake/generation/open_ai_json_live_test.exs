defmodule Cake.Generation.OpenAIJSONLiveTest do
  @moduledoc """
  `Cake.Generation.OpenAI.complete_json/3` against the real Responses API
  (#247, item 8), with the two schemas production actually sends: the
  atomic-or-flat decomposition schema `Cake.Decomposition.LLM` pairs with
  `Cake.Prompt.decomposition_prompt/1`, and `Cake.Prompt.ircot_schema/0`
  paired with `Cake.Prompt.ircot_prompt/3`. Drift against a toy schema
  would prove only that JSON mode works at all; drift against these is
  the signal worth paying for.

  Each reply round-trips through `ExJsonSchema` validation — the same
  validation `complete_json/3` applies before handing back `:parsed`, made
  explicit here — and `:parsed` is the decoded `:text`. Shapes only: which
  branch of a schema the model chose is `Cake.Decomposition.LLMLiveTest`'s
  and `Cake.Prompt.IRCoTLiveTest`'s concern.
  """

  use Cake.LiveLLMCase

  alias Cake.Generation.OpenAI
  alias Cake.Prompt

  @atomic_question "In what year did the Apollo 11 mission land on the Moon?"
  @compound_question "How does the population of Tokyo compare with the population of Delhi, " <>
                       "and which of the two cities covers the larger land area?"
  @ircot_question "What is the tallest mountain on Earth?"
  @wrong_key "sk-not-a-real-key"

  defp model, do: Application.get_env(:cake, :default_response_model, "gpt-4o-mini")

  # Red phase: routed through apply/3 so the suite compiles before
  # Cake.Decomposition.LLM.schema/0 exists (item 9).
  defp decomposition_schema, do: apply(Cake.Decomposition.LLM, :schema, [])

  describe "complete_json/3 with the decomposition schema Cake.Decomposition.LLM sends" do
    test "an atomic question round-trips as JSON that validates against the schema" do
      assert_decomposition_round_trip(@atomic_question)
    end

    test "a compound question round-trips as JSON that validates against the schema" do
      assert_decomposition_round_trip(@compound_question)
    end
  end

  describe "complete_json/3 with Prompt.ircot_schema/0" do
    test "a reasoning step round-trips as JSON that validates against the schema" do
      messages = Prompt.ircot_prompt(@ircot_question, [])

      assert {:ok, %{parsed: parsed, text: text}} =
               OpenAI.complete_json(messages, model(), schema: Prompt.ircot_schema())

      assert ExJsonSchema.Validator.valid?(Prompt.ircot_schema(), parsed)
      assert Jason.decode!(text) == parsed
      assert parsed |> Map.keys() |> Enum.sort() == ["reasoning", "retrieval_query"]
      assert String.trim(parsed["reasoning"]) != ""
      assert is_nil(parsed["retrieval_query"]) or String.trim(parsed["retrieval_query"]) != ""
    end
  end

  describe "complete_json/3 with a wrong key" do
    test "returns {:error, {:auth, _}} on the JSON path too" do
      configure_live!(@wrong_key)

      messages = Prompt.decomposition_prompt(@atomic_question)

      assert {:error, {:auth, detail}} =
               OpenAI.complete_json(messages, model(), schema: decomposition_schema())

      assert byte_size(detail) > 0
    end
  end

  # The decomposition prompt teaches two shapes — {"atomic": true} or
  # {"sub_questions": [...]} — and the schema admits no other key. Pin the
  # round trip and the key set; which shape the model chose is not asserted.
  defp assert_decomposition_round_trip(question) do
    messages = Prompt.decomposition_prompt(question)

    assert {:ok, %{parsed: parsed, text: text}} =
             OpenAI.complete_json(messages, model(), schema: decomposition_schema())

    assert ExJsonSchema.Validator.valid?(decomposition_schema(), parsed)
    assert Jason.decode!(text) == parsed
    assert parsed != %{}
    assert Map.keys(parsed) -- ["atomic", "sub_questions"] == []
  end
end
