defmodule Cake.ResponsesPropertyTest do
  @moduledoc """
  Property tests for `Cake.Responses.process/3`.

  Pins the totality invariant: for arbitrary binary `raw_text` (including
  malformed UTF-8, `[N]` markers pointing at hallucinated indices, empty
  strings, and large inputs) and arbitrary `indexed_chunks`, `process/3`
  must never crash and must return a well-shaped `%Result{}`.

  This codifies the "fallback on malformed responses" requirement from
  #114 as a structural invariant rather than a finite list of bad-input
  examples.

  Example tests live in `responses_test.exs`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cake.Responses
  alias Cake.Responses.Result
  alias Cake.Search.Provenance
  alias Cake.Test.StubChunk

  defp test_provenance, do: %Provenance{search_type: :hybrid, query_text: "test"}

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp metadata_struct do
    gen all(
          id <- string(:alphanumeric, min_length: 1, max_length: 8),
          label <- string(:alphanumeric, max_length: 16),
          source_ref <- one_of([constant(nil), string(:alphanumeric, max_length: 32)]),
          preview <- string(:alphanumeric, max_length: 24)
        ) do
      %{id: id, label: label, source_ref: source_ref, preview: preview, extras: %{}}
    end
  end

  defp scored_stub do
    gen all(metadata <- metadata_struct(), score <- float(min: 0.0, max: 1.0)) do
      %Cake.Search.Result{
        retrieval_unit: %StubChunk{metadata: metadata},
        relevance_score: score,
        hit_source: :search,
        index: "test_index",
        provenance: test_provenance()
      }
    end
  end

  defp indexed_chunks do
    gen all(stubs <- list_of(scored_stub(), max_length: 6)) do
      stubs
      |> Enum.with_index(1)
      |> Enum.map(fn {result, idx} -> {idx, result} end)
    end
  end

  # raw_text generators that exercise the parsing surface:
  #   - completely arbitrary binary (including invalid UTF-8)
  #   - text with random `[N]` markers (some valid, some hallucinated)
  defp raw_text do
    one_of([
      binary(),
      string(:utf8),
      gen all(
            parts <-
              list_of(
                one_of([
                  string(:alphanumeric, max_length: 8),
                  map(integer(0..32), fn n -> "[#{n}]" end)
                ]),
                max_length: 16
              )
          ) do
        Enum.join(parts, " ")
      end
    ])
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "process/3 never crashes and always returns a %Result{}" do
    check all(
            text <- raw_text(),
            chunks <- indexed_chunks()
          ) do
      result = Responses.process(text, chunks)
      assert %Result{} = result
    end
  end

  property "process/3 result fields have the documented shapes" do
    check all(
            text <- raw_text(),
            chunks <- indexed_chunks()
          ) do
      result = Responses.process(text, chunks)

      assert result.raw_text == text
      assert is_map(result.chunk_map)
      assert is_list(result.citations)
      assert is_list(result.warnings)
      assert is_list(result.actions)
      assert is_binary(result.final_text)
    end
  end

  property "every citation in the result corresponds to a chunk_map entry" do
    check all(
            text <- raw_text(),
            chunks <- indexed_chunks()
          ) do
      result = Responses.process(text, chunks)

      Enum.each(result.citations, fn citation ->
        assert Map.has_key?(result.chunk_map, citation.old_index)
      end)
    end
  end

  property "build_citation_map/1 keys exactly match the indexed_chunks indices" do
    check all(chunks <- indexed_chunks()) do
      map = Responses.build_citation_map(chunks)
      indices = Enum.map(chunks, fn {idx, _} -> idx end)
      assert Enum.sort(Map.keys(map)) == Enum.sort(indices)
    end
  end
end
