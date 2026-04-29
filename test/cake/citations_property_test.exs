defmodule Cake.CitationsPropertyTest do
  @moduledoc """
  Property tests for `Cake.Citations.extract/2`.

  Pins the structural invariants of citation extraction against arbitrary
  text and arbitrary chunk_maps. Example tests live in `citations_test.exs`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cake.Citations

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp positive_index, do: integer(1..32)

  defp metadata do
    gen all(
          id <- string(:alphanumeric, min_length: 1, max_length: 8),
          label <- string(:alphanumeric, max_length: 16)
        ) do
      %{id: id, label: label, extras: %{}, source_ref: nil, preview: ""}
    end
  end

  defp chunk_map do
    gen all(entries <- list_of(tuple({positive_index(), metadata()}), max_length: 8)) do
      Map.new(entries)
    end
  end

  # Generates a string that interleaves random words with `[N]` markers,
  # where N is drawn from the given index pool to control overlap with
  # the chunk_map keys.
  defp text_with_markers(index_pool) do
    gen all(
          parts <-
            list_of(
              one_of([
                string(:alphanumeric, max_length: 8),
                map(member_of(index_pool), fn n -> "[#{n}]" end)
              ]),
              max_length: 16
            )
        ) do
      Enum.join(parts, " ")
    end
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "valid citations are always a subset of chunk_map keys" do
    check all(
            map <- chunk_map(),
            text <- text_with_markers(Enum.to_list(1..32))
          ) do
      {valid, _hallucinated} = Citations.extract(text, map)

      valid_indices = Enum.map(valid, & &1.index)
      assert Enum.all?(valid_indices, &Map.has_key?(map, &1))
    end
  end

  property "hallucinated indices are disjoint from chunk_map keys" do
    check all(
            map <- chunk_map(),
            text <- text_with_markers(Enum.to_list(1..32))
          ) do
      {_valid, hallucinated} = Citations.extract(text, map)
      assert Enum.all?(hallucinated, fn idx -> not Map.has_key?(map, idx) end)
    end
  end

  property "valid ∪ hallucinated equals the unique markers in the text" do
    check all(
            map <- chunk_map(),
            text <- text_with_markers(Enum.to_list(1..32))
          ) do
      {valid, hallucinated} = Citations.extract(text, map)

      returned = Enum.sort(Enum.map(valid, & &1.index) ++ hallucinated)

      from_text =
        ~r/\[(\d+)\]/
        |> Regex.scan(text)
        |> Enum.map(fn [_, n] -> String.to_integer(n) end)
        |> Enum.uniq()
        |> Enum.sort()

      assert returned == from_text
    end
  end

  property "valid citations are returned in first-appearance order" do
    check all(
            map <- chunk_map(),
            text <- text_with_markers(Enum.to_list(1..32))
          ) do
      {valid, _} = Citations.extract(text, map)

      first_appearance =
        ~r/\[(\d+)\]/
        |> Regex.scan(text)
        |> Enum.map(fn [_, n] -> String.to_integer(n) end)
        |> Enum.uniq()
        |> Enum.filter(&Map.has_key?(map, &1))

      assert Enum.map(valid, & &1.index) == first_appearance
    end
  end

  property "extract is deterministic for the same inputs" do
    check all(
            map <- chunk_map(),
            text <- text_with_markers(Enum.to_list(1..32))
          ) do
      assert Citations.extract(text, map) == Citations.extract(text, map)
    end
  end

  property "extract is total — never crashes on arbitrary binary text" do
    check all(
            text <- binary(),
            map <- chunk_map()
          ) do
      assert {valid, hallucinated} = Citations.extract(text, map)
      assert is_list(valid)
      assert is_list(hallucinated)
    end
  end

  property "carrier metadata equals the chunk_map value for that index" do
    check all(
            map <- chunk_map(),
            text <- text_with_markers(Enum.to_list(1..32))
          ) do
      {valid, _} = Citations.extract(text, map)

      Enum.each(valid, fn %{index: idx, metadata: md} ->
        assert md == Map.fetch!(map, idx)
      end)
    end
  end
end
