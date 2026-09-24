defmodule Cake.Decomposition.LLMLiveTest do
  @moduledoc """
  `Cake.Decomposition.LLM.decompose/2` against the real provider (#247,
  item 10), with its production defaults — `Cake.Generation.OpenAI` and
  the model it ships with — so what is exercised is exactly what a
  `Cake.Conversation` turn sends.

  Two invariants, one per branch of the prompt: an obviously atomic
  question comes back atomic (`strategy: :none`), and an obviously
  compound one comes back as a dependency-free flat DAG (`strategy:
  :flat`, every entry `depends_on: []`) — which also proves live output
  survives `Cake.Decomposition.Result.new/2`'s DAG validation rather than
  raising. The sub-questions' wording is never asserted.
  """

  use Cake.LiveLLMCase

  alias Cake.Decomposition.LLM
  alias Cake.Decomposition.Result

  @atomic_question "What is the boiling point of water at sea level, in degrees Celsius?"
  @compound_question "How does the population of Tokyo compare with the population of Delhi, " <>
                       "and which of the two cities covers the larger land area?"

  describe "decompose/2 with the production generation module and model" do
    test "an obviously atomic question yields an atomic Result" do
      assert {:ok, %Result{} = result} = LLM.decompose(@atomic_question)

      assert result.original_question == @atomic_question
      assert result.strategy == :none
      assert result.sub_questions == []
      assert result.question_index == %{}
    end

    test "an obviously compound question yields a dependency-free flat DAG" do
      assert {:ok, %Result{} = result} = LLM.decompose(@compound_question)

      assert result.original_question == @compound_question
      assert result.strategy == :flat
      assert length(result.sub_questions) >= 2

      for entry <- result.sub_questions do
        assert %{question: question, depends_on: []} = entry
        assert String.trim(question) != ""
      end

      expected_index =
        result.sub_questions
        |> Enum.with_index()
        |> Map.new(fn {entry, index} -> {index, entry} end)

      assert result.question_index == expected_index
    end
  end
end
