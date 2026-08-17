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

    test "string sub-questions normalize to a degenerate flat DAG" do
      question = "Compare A and B"
      sub_question_a = "What is A?"
      sub_question_b = "What is B?"
      entry_a = %{question: sub_question_a, depends_on: []}
      entry_b = %{question: sub_question_b, depends_on: []}

      result = Result.new(question, [sub_question_a, sub_question_b])

      assert result.original_question == question
      assert result.strategy == :flat
      assert result.sub_questions == [entry_a, entry_b]
      assert result.question_index == %{0 => entry_a, 1 => entry_b}
    end

    test "entry maps pass through, preserving dependencies (strategy :sequential)" do
      entry_a = %{question: "What is A?", depends_on: []}
      entry_b = %{question: "Given A, what is B?", depends_on: [0]}

      result = Result.new("Compare A and B", [entry_a, entry_b])

      assert result.strategy == :sequential
      assert result.sub_questions == [entry_a, entry_b]
      assert result.question_index == %{0 => entry_a, 1 => entry_b}
    end

    test "a dependency-free entry list is strategy :flat" do
      entries = [
        %{question: "What is A?", depends_on: []},
        %{question: "What is B?", depends_on: []}
      ]

      result = Result.new("Compare A and B", entries)

      assert result.strategy == :flat
      assert result.sub_questions == entries
    end

    test "strings and entry maps can mix, normalizing uniformly" do
      sub_question_a = "What is A?"
      entry_b = %{question: "Given A, what is B?", depends_on: [0]}

      result = Result.new("Compare A and B", [sub_question_a, entry_b])

      assert result.strategy == :sequential

      assert result.sub_questions == [
               %{question: sub_question_a, depends_on: []},
               entry_b
             ]
    end
  end

  describe "new/2 DAG validation" do
    test "an out-of-range dependency raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        Result.new("q", [%{question: "What is A?", depends_on: [1]}])
      end
    end

    test "a self-dependency raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        Result.new("q", [
          %{question: "What is A?", depends_on: []},
          %{question: "What is B?", depends_on: [1]}
        ])
      end
    end

    test "a dependency cycle raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        Result.new("q", [
          %{question: "What is A?", depends_on: [1]},
          %{question: "What is B?", depends_on: [0]}
        ])
      end
    end

    test "a non-integer dependency raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        Result.new("q", [%{question: "What is A?", depends_on: ["0"]}])
      end
    end

    test "a malformed entry raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        Result.new("q", [%{text: "missing the :question key"}])
      end
    end
  end
end
