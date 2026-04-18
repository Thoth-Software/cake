defmodule Cake.Search.QueryTest do
  use ExUnit.Case, async: true

  alias Cake.Search.Query

  describe "new/2" do
    test "returns a struct with the given index and defaults" do
      query = Query.new("docs")

      assert query.index == "docs"
      assert query.size == 10
      assert query.must == []
      assert query.should == []
      assert query.filter == []
      assert query.min_score == nil
    end

    test "accepts :size option" do
      query = Query.new("docs", size: 25)
      assert query.size == 25
    end

    test "accepts :min_score option" do
      query = Query.new("docs", min_score: 0.7)
      assert query.min_score == 0.7
    end
  end

  describe "knn/4" do
    test "adds a correctly-shaped knn clause to must" do
      vector = [0.1, 0.2, 0.3, 0.4]
      query = Query.knn(Query.new("docs"), "embedding", vector, 10)

      assert [clause] = query.must
      assert clause == %{"knn" => %{"embedding" => %{"vector" => vector, "k" => 10}}}
    end

    test "is additive — each call appends another clause" do
      base = Query.new("docs")

      query =
        base
        |> Query.knn("embedding", [0.1], 5)
        |> Query.knn("embedding", [0.2], 5)

      assert length(query.must) == 2
    end
  end

  describe "match/4" do
    test "adds a correctly-shaped multi_match clause to should" do
      query = Query.match(Query.new("docs"), "GenServer", ["title", "text"])

      assert [clause] = query.should

      assert clause == %{
               "multi_match" => %{
                 "query" => "GenServer",
                 "fields" => ["title", "text"],
                 "boost" => 1.0
               }
             }
    end

    test "respects the :boost option" do
      query = Query.match(Query.new("docs"), "GenServer", ["title"], boost: 2.5)
      assert [%{"multi_match" => %{"boost" => 2.5}}] = query.should
    end
  end

  describe "filter_term/3" do
    test "adds a correctly-shaped term clause to filter" do
      query = Query.filter_term(Query.new("docs"), "language", "Elixir")

      assert [clause] = query.filter
      assert clause == %{"term" => %{"language" => "Elixir"}}
    end
  end

  describe "min_score/2" do
    test "is nil by default" do
      assert Query.new("docs").min_score == nil
    end

    test "sets the min_score field" do
      query = Query.min_score(Query.new("docs"), 0.5)
      assert query.min_score == 0.5
    end
  end

  describe "size/2" do
    test "overrides the default" do
      query = Query.size(Query.new("docs"), 50)
      assert query.size == 50
    end
  end

  describe "to_query_map/1" do
    test "produces the expected nested structure for a known input" do
      vector = [0.1, 0.2]
      base = Query.new("docs", size: 5, min_score: 0.4)

      result =
        base
        |> Query.knn("embedding", vector, 3)
        |> Query.match("Supervisor", ["title"])
        |> Query.filter_term("language", "Elixir")
        |> Query.to_query_map()

      assert result.size == 5
      assert result.min_score == 0.4

      assert result.query.bool.must == [
               %{"knn" => %{"embedding" => %{"vector" => vector, "k" => 3}}}
             ]

      assert result.query.bool.should == [
               %{"multi_match" => %{"query" => "Supervisor", "fields" => ["title"], "boost" => 1.0}}
             ]

      assert result.query.bool.filter == [%{"term" => %{"language" => "Elixir"}}]
    end

    test "omits min_score when nil" do
      result = Query.to_query_map(Query.new("docs"))
      refute Map.has_key?(result, :min_score)
    end

    test "preserves clause insertion order" do
      base = Query.new("docs")

      result =
        base
        |> Query.filter_term("a", "first")
        |> Query.filter_term("b", "second")
        |> Query.filter_term("c", "third")
        |> Query.to_query_map()

      assert result.query.bool.filter == [
               %{"term" => %{"a" => "first"}},
               %{"term" => %{"b" => "second"}},
               %{"term" => %{"c" => "third"}}
             ]
    end
  end
end
