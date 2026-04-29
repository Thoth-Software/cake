defmodule Cake.Search.QueryPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cake.QueryGenerators
  alias Cake.Search.Query

  # ---------------------------------------------------------------------------
  # Composition properties
  # ---------------------------------------------------------------------------

  property "clause builders are additive" do
    check all(
            query <- QueryGenerators.query(),
            steps <- QueryGenerators.builder_sequence()
          ) do
      result = QueryGenerators.apply_sequence(query, steps)

      knn_count = Enum.count(steps, &match?({:knn, _, _, _}, &1))
      match_count = Enum.count(steps, &match?({:match, _, _, _}, &1))
      filter_count = Enum.count(steps, &match?({:filter_term, _, _}, &1))

      assert length(result.must) == length(query.must) + knn_count
      assert length(result.should) == length(query.should) + match_count
      assert length(result.filter) == length(query.filter) + filter_count
    end
  end

  property "scalar fields take the last written value" do
    check all(
            query <- QueryGenerators.query(),
            steps <- QueryGenerators.builder_sequence()
          ) do
      result = QueryGenerators.apply_sequence(query, steps)

      last_size_step = steps |> Enum.filter(&match?({:size, _}, &1)) |> List.last()
      last_min_score_step = steps |> Enum.filter(&match?({:min_score, _}, &1)) |> List.last()

      expected_size = if last_size_step, do: elem(last_size_step, 1), else: query.size

      expected_min_score =
        if last_min_score_step, do: elem(last_min_score_step, 1), else: query.min_score

      assert result.size == expected_size
      assert result.min_score == expected_min_score
    end
  end

  property "permutations of builder steps produce the same clause sets" do
    check all(steps <- QueryGenerators.builder_sequence()) do
      base = Query.new("test")
      result1 = QueryGenerators.apply_sequence(base, steps)
      result2 = QueryGenerators.apply_sequence(base, Enum.shuffle(steps))

      assert MapSet.new(result1.must) == MapSet.new(result2.must)
      assert MapSet.new(result1.should) == MapSet.new(result2.should)
      assert MapSet.new(result1.filter) == MapSet.new(result2.filter)
    end
  end

  # ---------------------------------------------------------------------------
  # Conversion properties
  # ---------------------------------------------------------------------------

  property "to_query_map/1 always produces a map with the correct shape" do
    check all(query <- QueryGenerators.query()) do
      map = Query.to_query_map(query)

      assert is_integer(map.size)
      assert is_list(get_in(map, [:query, :bool, :must]))
      assert is_list(get_in(map, [:query, :bool, :should]))
      assert is_list(get_in(map, [:query, :bool, :filter]))
    end
  end

  property "to_query_map/1 preserves clause counts" do
    check all(query <- QueryGenerators.query()) do
      map = Query.to_query_map(query)

      assert length(get_in(map, [:query, :bool, :must])) == length(query.must)
      assert length(get_in(map, [:query, :bool, :should])) == length(query.should)
      assert length(get_in(map, [:query, :bool, :filter])) == length(query.filter)
    end
  end

  property "to_query_map/1 preserves clause content" do
    check all(query <- QueryGenerators.query()) do
      map = Query.to_query_map(query)

      assert MapSet.new(get_in(map, [:query, :bool, :must])) == MapSet.new(query.must)
      assert MapSet.new(get_in(map, [:query, :bool, :should])) == MapSet.new(query.should)
      assert MapSet.new(get_in(map, [:query, :bool, :filter])) == MapSet.new(query.filter)
    end
  end

  property "to_query_map/1 includes min_score iff it is non-nil" do
    check all(query <- QueryGenerators.query()) do
      map = Query.to_query_map(query)

      if is_nil(query.min_score) do
        refute Map.has_key?(map, :min_score)
      else
        assert Map.has_key?(map, :min_score)
        assert map.min_score == query.min_score
      end
    end
  end
end
