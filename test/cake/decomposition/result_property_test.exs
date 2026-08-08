defmodule Cake.Decomposition.ResultPropertyTest do
  @moduledoc """
  Structural invariants of `Cake.Decomposition.Result.new/2`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cake.Decomposition.Result

  property "sub_questions is always a list and question_index keys are exactly 0..length-1" do
    check all(
            question <- StreamData.string(:printable, min_length: 1),
            sub_questions <- StreamData.list_of(StreamData.string(:printable))
          ) do
      result = Result.new(question, sub_questions)

      assert is_list(result.sub_questions)
      assert result.sub_questions == sub_questions

      expected_keys =
        case sub_questions do
          [] -> []
          list -> Enum.to_list(0..(length(list) - 1))
        end

      assert result.question_index |> Map.keys() |> Enum.sort() == expected_keys

      # Every index maps back to the sub-question at that position.
      for {index, text} <- result.question_index do
        assert Enum.at(sub_questions, index) == text
      end
    end
  end
end
