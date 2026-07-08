defmodule Cake.Search.ResultTest do
  use ExUnit.Case, async: true

  alias Cake.Search.Provenance
  alias Cake.Search.Result

  defp provenance do
    %Provenance{search_type: :hybrid, query_text: "test query"}
  end

  describe "new_from_search/4" do
    test "builds a Result with hit_source :search and the given score" do
      unit = %{id: "u1", text: "hello"}
      prov = provenance()
      result = Result.new_from_search(unit, 4.2, "my_index", prov)

      assert result.retrieval_unit == unit
      assert result.backend_score == 4.2
      assert result.hit_source == :search
      assert result.index == "my_index"
      assert result.provenance == prov
      assert result.cosine_score == nil
      assert result.relevance_score == nil
      assert result.prompt_index == nil
    end

    test "accepts nil score for hits without a backend score" do
      result = Result.new_from_search(%{id: "u2"}, nil, "idx", provenance())
      assert result.backend_score == nil
    end
  end

  describe "new_from_expansion/3" do
    test "builds a Result with hit_source :expansion and no backend score" do
      unit = %{id: "u3", text: "neighbor"}
      prov = provenance()
      result = Result.new_from_expansion(unit, "my_index", prov)

      assert result.retrieval_unit == unit
      assert result.backend_score == nil
      assert result.hit_source == :expansion
      assert result.index == "my_index"
      assert result.provenance == prov
    end
  end
end
