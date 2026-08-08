defmodule Cake.Decomposition.ResultTest do
  use ExUnit.Case, async: true

  alias Cake.Decomposition.Result

  describe "new/2" do
    test "a question with no sub-questions is atomic (strategy :none)" do
      result = Result.new("What is the boiling point of water?")

      assert result.original_question == "What is the boiling point of water?"
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
      result = Result.new("Compare A and B", ["What is A?", "What is B?"])

      assert result.original_question == "Compare A and B"
      assert result.strategy == :flat
      assert result.sub_questions == ["What is A?", "What is B?"]
      assert result.question_index == %{0 => "What is A?", 1 => "What is B?"}
    end
  end
end
