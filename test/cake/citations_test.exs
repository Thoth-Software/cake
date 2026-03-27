defmodule Cake.CitationsTest do
  use ExUnit.Case, async: true

  alias Cake.Citations

  @chunk_map %{
    1 => %{package: "Enum", title: "map/2", url: "https://hexdocs.pm/elixir/Enum.html#map/2"},
    2 => %{package: "Enum", title: "filter/2", url: "https://hexdocs.pm/elixir/Enum.html#filter/2"},
    3 => %{package: "Task", title: "async/1", url: "https://hexdocs.pm/elixir/Task.html#async/1"}
  }

  test "extracts valid citations from response text" do
    response = "Use map/2 [1] and filter/2 [3] for this."

    assert Citations.extract(response, @chunk_map) == [
             %{index: 1, package: "Enum", title: "map/2", url: "https://hexdocs.pm/elixir/Enum.html#map/2"},
             %{index: 3, package: "Task", title: "async/1", url: "https://hexdocs.pm/elixir/Task.html#async/1"}
           ]
  end

  test "drops hallucinated citations not in chunk_map" do
    response = "This is supported [1] and also [99]."

    assert Citations.extract(response, @chunk_map) == [
             %{index: 1, package: "Enum", title: "map/2", url: "https://hexdocs.pm/elixir/Enum.html#map/2"}
           ]
  end

  test "returns empty list when no citations present" do
    response = "There are no citations in this response."

    assert Citations.extract(response, @chunk_map) == []
  end

  test "deduplicates repeated citations" do
    response = "Use map/2 [1] and also map/2 again [1]."

    assert Citations.extract(response, @chunk_map) == [
             %{index: 1, package: "Enum", title: "map/2", url: "https://hexdocs.pm/elixir/Enum.html#map/2"}
           ]
  end
end
