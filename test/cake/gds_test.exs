defmodule Cake.GDSTest do
  use ExUnit.Case, async: true

  alias Cake.Support.FixtureGDS

  describe "use Cake.GDS" do
    test "injects the Cake.GDS behaviour" do
      behaviours = FixtureGDS.__info__(:attributes)[:behaviour] || []
      assert Cake.GDS in behaviours
    end

    test "provides a default expand_with_neighbors/2 that returns units unchanged" do
      units = [%{id: 1}, %{id: 2}]
      assert FixtureGDS.expand_with_neighbors(units, 5) == units
    end

    test "default expand_with_neighbors/2 works with an empty list" do
      assert FixtureGDS.expand_with_neighbors([], 3) == []
    end
  end
end
