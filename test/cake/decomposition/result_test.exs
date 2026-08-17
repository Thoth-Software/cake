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

    test "entries without dependencies yield strategy :flat (the degenerate DAG)" do
      question = "Compare A and B"
      entry_a = %{question: "What is A?", depends_on: []}
      entry_b = %{question: "What is B?", depends_on: []}

      result = Result.new(question, [entry_a, entry_b])

      assert result.original_question == question
      assert result.strategy == :flat
      assert result.sub_questions == [entry_a, entry_b]
      assert result.question_index == %{0 => entry_a, 1 => entry_b}
    end

    test "any entry with a dependency yields strategy :sequential" do
      entry_a = %{question: "What products are in the RO line?", depends_on: []}
      entry_b = %{question: "Which of those support hot feed water?", depends_on: [0]}

      result = Result.new("Which RO products support hot feed water?", [entry_a, entry_b])

      assert result.strategy == :sequential
      assert result.sub_questions == [entry_a, entry_b]
      assert result.question_index == %{0 => entry_a, 1 => entry_b}
    end

    test "an entry may depend on several sub-questions" do
      entry_a = %{question: "What is the RO-400 flow rate?", depends_on: []}
      entry_b = %{question: "What is the RO-500 flow rate?", depends_on: []}
      entry_c = %{question: "Given both flow rates, which is higher?", depends_on: [0, 1]}

      result = Result.new("Which flows faster?", [entry_a, entry_b, entry_c])

      assert result.strategy == :sequential
      assert result.sub_questions == [entry_a, entry_b, entry_c]
    end

    test "a dependency on a later list position is still a valid DAG" do
      # List position carries no ordering semantics — only the edges do.
      entry_a = %{question: "Which of those support hot feed water?", depends_on: [1]}
      entry_b = %{question: "What products are in the RO line?", depends_on: []}

      result = Result.new("Which RO products support hot feed water?", [entry_a, entry_b])

      assert result.strategy == :sequential
      assert result.sub_questions == [entry_a, entry_b]
    end

    test "a depends_on index outside 0..length-1 raises ArgumentError" do
      entries = [
        %{question: "What is A?", depends_on: []},
        %{question: "What is B?", depends_on: [2]}
      ]

      assert_raise ArgumentError, fn -> Result.new("Compare A and B", entries) end
    end

    test "a self-dependency raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        Result.new("q", [%{question: "What is A?", depends_on: [0]}])
      end
    end

    test "a dependency cycle raises ArgumentError" do
      entries = [
        %{question: "What is A?", depends_on: [1]},
        %{question: "What is B?", depends_on: [0]}
      ]

      assert_raise ArgumentError, fn -> Result.new("Compare A and B", entries) end
    end
  end
end
