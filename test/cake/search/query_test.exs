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

    test "includes ef_search in the knn clause when provided" do
      vector = [0.1, 0.2, 0.3]
      query = Query.knn(Query.new("docs"), "embedding", vector, 10, ef_search: 128)

      assert [clause] = query.must
      knn_body = clause["knn"]["embedding"]
      assert knn_body["vector"] == vector
      assert knn_body["k"] == 10
      assert knn_body["ef_search"] == 128
    end

    test "omits ef_search from the knn clause when not provided" do
      vector = [0.1, 0.2, 0.3]
      query = Query.knn(Query.new("docs"), "embedding", vector, 10)

      assert [clause] = query.must
      knn_body = clause["knn"]["embedding"]
      refute Map.has_key?(knn_body, "ef_search")
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
end
