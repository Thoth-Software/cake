defmodule Cake.Search.HitTest do
  use ExUnit.Case, async: true

  alias Cake.Search.Hit

  describe "struct" do
    test "enforces :id" do
      assert_raise ArgumentError, fn -> struct!(Hit, %{score: 1.0}) end
    end

    test "defaults score to nil and source to empty map" do
      hit = %Hit{id: "abc"}
      assert hit.score == nil
      assert hit.source == %{}
    end

    test "accepts all fields" do
      hit = %Hit{id: "abc", score: 0.95, source: %{"text" => "hello"}}
      assert hit.id == "abc"
      assert hit.score == 0.95
      assert hit.source == %{"text" => "hello"}
    end
  end
end
