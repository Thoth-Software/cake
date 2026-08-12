defmodule Cake.Search.ProvenanceTest do
  use ExUnit.Case, async: true

  alias Cake.Search.Provenance

  describe "sub_question_index" do
    test "defaults to nil alongside the other decomposition fields" do
      provenance = %Provenance{search_type: :hybrid, query_text: "q"}

      assert provenance.sub_question_index == nil
      assert provenance.decomposed == false
      assert provenance.original_query == nil
    end

    test "carries a positional index for a decomposed sub-question search" do
      question = "Compare A and B"
      sub_question = "What is B?"

      provenance =
        struct!(Provenance,
          search_type: :hybrid,
          query_text: sub_question,
          decomposed: true,
          original_query: question,
          sub_question_index: 1
        )

      assert provenance.sub_question_index == 1
      assert provenance.query_text == sub_question
      assert provenance.original_query == question
    end

    test "index zero is a valid position" do
      provenance =
        struct!(Provenance,
          search_type: :vector,
          query_text: "What is A?",
          decomposed: true,
          original_query: "Compare A and B",
          sub_question_index: 0
        )

      assert provenance.sub_question_index == 0
    end
  end
end
