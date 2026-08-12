defmodule Cake.Decomposition.ResultTest do
  use ExUnit.Case, async: true

  alias Cake.Decomposition.Result

  describe "new/2" do
    test "a question with no sub-questions is atomic (strategy :none)" do
      question = "What is the boiling point of water?"

      result = Result.new(question)

      assert result.original_question == question
      assert result.strategy == :none
      assert result.sub_questions == []
      assert result.question_index == %{}
    end

    test "an explicit empty sub-question list is also atomic" do
      result = Result.new("q", [])

      assert result.strategy == :none
      assert result.sub_questions == []
      assert result.question_index == %{}
    end

    test "sub-questions yield strategy :flat with a positional index" do
      question = "Compare A and B"
      sub_question_a = "What is A?"
      sub_question_b = "What is B?"

      result = Result.new(question, [sub_question_a, sub_question_b])

      assert result.original_question == question
      assert result.strategy == :flat
      assert result.sub_questions == [sub_question_a, sub_question_b]
      assert result.question_index == %{0 => sub_question_a, 1 => sub_question_b}
    end
  end
end
