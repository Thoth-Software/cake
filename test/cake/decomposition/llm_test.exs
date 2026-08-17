defmodule Cake.Decomposition.LLMTest do
  use ExUnit.Case, async: true

  import Mox

  alias Cake.Decomposition.LLM
  alias Cake.Decomposition.Result

  setup :verify_on_exit!

  @question "How does the RO-400 filter compare to the RO-500?"

  defp completion(parsed) do
    {:ok,
     %{
       text: Jason.encode!(parsed),
       finish_reason: :stop,
       usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15},
       model: "test-model",
       parsed: parsed
     }}
  end

  describe "decompose/2" do
    test "sends the decomposition prompt and a JSON schema to the generation module" do
      expect(Cake.Generation.Mock, :complete_json, fn messages, _model, opts ->
        assert messages == Cake.Prompt.decomposition_prompt(@question)

        schema = Keyword.fetch!(opts, :schema)
        assert schema["type"] == "object"
        assert Map.has_key?(schema["properties"], "atomic")
        assert Map.has_key?(schema["properties"], "sub_questions")

        completion(%{"atomic" => true})
      end)

      assert {:ok, %Result{}} = LLM.decompose(@question, generation: Cake.Generation.Mock)
    end

    test "an atomic response produces strategy :none with no sub-questions" do
      expect(Cake.Generation.Mock, :complete_json, fn _messages, _model, _opts ->
        completion(%{"atomic" => true})
      end)

      assert {:ok, result} = LLM.decompose(@question, generation: Cake.Generation.Mock)
      assert result.original_question == @question
      assert result.strategy == :none
      assert result.sub_questions == []
      assert result.question_index == %{}
    end

    test "a decomposed response produces a dependency-free flat DAG" do
      sub_question_a = "What are the specs of the RO-400?"
      sub_question_b = "What are the specs of the RO-500?"
      entry_a = %{question: sub_question_a, depends_on: []}
      entry_b = %{question: sub_question_b, depends_on: []}

      expect(Cake.Generation.Mock, :complete_json, fn _messages, _model, _opts ->
        completion(%{"sub_questions" => [sub_question_a, sub_question_b]})
      end)

      assert {:ok, result} = LLM.decompose(@question, generation: Cake.Generation.Mock)
      assert result.original_question == @question
      assert result.strategy == :flat
      assert result.sub_questions == [entry_a, entry_b]
      assert result.question_index == %{0 => entry_a, 1 => entry_b}
    end

    test "an empty sub-question list collapses to an atomic result" do
      expect(Cake.Generation.Mock, :complete_json, fn _messages, _model, _opts ->
        completion(%{"sub_questions" => []})
      end)

      assert {:ok, result} = LLM.decompose(@question, generation: Cake.Generation.Mock)
      assert result.strategy == :none
      assert result.sub_questions == []
    end

    test "a generation error propagates wrapped in {:generation, reason}" do
      expect(Cake.Generation.Mock, :complete_json, fn _messages, _model, _opts ->
        {:error, {:timeout, 60_000}}
      end)

      assert {:error, {:generation, {:timeout, 60_000}}} =
               LLM.decompose(@question, generation: Cake.Generation.Mock)
    end

    test "valid JSON in an unexpected shape returns {:invalid_response, _}" do
      expect(Cake.Generation.Mock, :complete_json, fn _messages, _model, _opts ->
        completion(%{"answer" => "the RO-500 has a higher flow rate"})
      end)

      assert {:error, {:invalid_response, description}} =
               LLM.decompose(@question, generation: Cake.Generation.Mock)

      assert description =~ "answer"
    end
  end
end
