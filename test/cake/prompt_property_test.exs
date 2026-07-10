defmodule Cake.PromptPropertyTest do
  @moduledoc """
  Property tests for `Cake.Prompt`.

  Pins structural invariants of `build/4` (the assembled prompt) and
  `prepare_context/2` (relevance filtering and dense indexing).

  Example tests live in `prompt_test.exs`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cake.Prompt
  alias Cake.Search.Provenance
  alias Cake.Search.Result
  alias Cake.Test.ConvoChunk

  defp test_provenance, do: %Provenance{search_type: :hybrid, query_text: "test"}

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp prompt_text do
    string(:alphanumeric, min_length: 1, max_length: 20)
  end

  defp scored_chunk do
    gen all(
          text <- prompt_text(),
          score <- float(min: 0.0, max: 1.0)
        ) do
      %Result{
        retrieval_unit: %ConvoChunk{prompt_text: text},
        relevance_score: score,
        hit_source: :search,
        index: "test_index",
        provenance: test_provenance()
      }
    end
  end

  defp indexed_chunks do
    gen all(chunks <- list_of(scored_chunk(), min_length: 1, max_length: 8)) do
      chunks
      |> Enum.with_index(1)
      |> Enum.map(fn {result, idx} -> {idx, result} end)
    end
  end

  defp history do
    list_of(string(:alphanumeric, min_length: 1, max_length: 16), max_length: 12)
  end

  defp question do
    string(:alphanumeric, min_length: 1, max_length: 32)
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  defp system_content(messages) do
    [%{role: "system", content: content} | _] = messages
    content
  end

  property "every formatted chunk appears in the system message" do
    check all(
            chunks <- indexed_chunks(),
            q <- question(),
            h <- history()
          ) do
      messages = Prompt.build(chunks, q, h)
      system = system_content(messages)

      Enum.each(chunks, fn indexed ->
        assert String.contains?(system, Prompt.format_chunk(indexed))
      end)
    end
  end

  property "formatted chunks appear in indexed order in the system message" do
    check all(
            chunks <- indexed_chunks(),
            q <- question(),
            h <- history()
          ) do
      messages = Prompt.build(chunks, q, h)

      # The system prompt's preamble contains literal "[1], [2]" examples,
      # so binary-matching against the full system message can return
      # offsets inside the preamble rather than the data section. Split
      # on "Context:" so the property scopes to the data block only.
      data_section =
        messages
        |> system_content()
        |> String.split("Context:", parts: 2)
        |> List.last()

      offsets =
        Enum.map(chunks, fn indexed ->
          formatted = Prompt.format_chunk(indexed)
          {start, _len} = :binary.match(data_section, formatted)
          start
        end)

      assert offsets == Enum.sort(offsets)
    end
  end

  property "count of [N] markers in the system message equals length(indexed_chunks)" do
    check all(
            chunks <- indexed_chunks(),
            q <- question(),
            h <- history()
          ) do
      messages = Prompt.build(chunks, q, h)
      system = system_content(messages)

      # Strip the bracketed-citation guidance text "like [1], [2]" from the
      # system prompt before counting — those literal example markers are
      # not data-driven and would otherwise pad the count.
      data_section = system |> String.split("Context:", parts: 2) |> List.last()

      marker_count =
        ~r/\[(\d+)\]/
        |> Regex.scan(data_section)
        |> length()

      assert marker_count == length(chunks)
    end
  end

  property "the user message at the tail equals the question verbatim" do
    check all(
            chunks <- indexed_chunks(),
            q <- question(),
            h <- history()
          ) do
      messages = Prompt.build(chunks, q, h)
      assert List.last(messages) == %{role: "user", content: q}
    end
  end

  property "build/4 with empty indexed_chunks uses the no-context system message" do
    check all(q <- question(), h <- history()) do
      messages = Prompt.build([], q, h)
      system = system_content(messages)
      assert system =~ "no relevant reference material"
    end
  end

  # ---------------------------------------------------------------------------
  # prepare_context/2 generators
  # ---------------------------------------------------------------------------

  defp scored_result_for_context do
    gen all(
          text <- prompt_text(),
          score <- float(min: 0.0, max: 1.0)
        ) do
      %Result{
        retrieval_unit: %ConvoChunk{
          prompt_text: text,
          metadata: %{id: text, label: "L", preview: "p", source_ref: nil, extras: %{}}
        },
        relevance_score: score,
        hit_source: :search,
        index: "test_index",
        provenance: test_provenance()
      }
    end
  end

  defp context_opts do
    gen all(
          max_chunks <- integer(1..20),
          min_relevance <- float(min: 0.0, max: 1.0)
        ) do
      [max_chunks: max_chunks, min_relevance: min_relevance]
    end
  end

  # ---------------------------------------------------------------------------
  # prepare_context/2 properties
  # ---------------------------------------------------------------------------

  property "prepare_context/2 output length is bounded by max_chunks and input length" do
    check all(
            results <- list_of(scored_result_for_context(), max_length: 15),
            opts <- context_opts()
          ) do
      {indexed, _quality} = Prompt.prepare_context(results, opts)
      max_chunks = Keyword.get(opts, :max_chunks)

      assert length(indexed) <= max_chunks
      assert length(indexed) <= length(results)
    end
  end

  property "prepare_context/2 all output results meet the relevance floor" do
    check all(
            results <- list_of(scored_result_for_context(), max_length: 15),
            opts <- context_opts()
          ) do
      {indexed, _quality} = Prompt.prepare_context(results, opts)
      min_relevance = Keyword.get(opts, :min_relevance)

      Enum.each(indexed, fn {_idx, result} ->
        assert result.relevance_score >= min_relevance
      end)
    end
  end

  property "prepare_context/2 indices are dense 1..N" do
    check all(
            results <- list_of(scored_result_for_context(), max_length: 15),
            opts <- context_opts()
          ) do
      {indexed, _quality} = Prompt.prepare_context(results, opts)
      indices = Enum.map(indexed, fn {idx, _} -> idx end)
      n = length(indexed)
      expected = if n > 0, do: Enum.to_list(1..n), else: []

      assert indices == expected
    end
  end

  property "prepare_context/2 each result's prompt_index matches its tuple position" do
    check all(
            results <- list_of(scored_result_for_context(), max_length: 15),
            opts <- context_opts()
          ) do
      {indexed, _quality} = Prompt.prepare_context(results, opts)

      Enum.each(indexed, fn {idx, result} ->
        assert result.prompt_index == idx
      end)
    end
  end

  property "prepare_context/2 context quality is :none iff output is empty" do
    check all(
            results <- list_of(scored_result_for_context(), max_length: 15),
            opts <- context_opts()
          ) do
      {indexed, quality} = Prompt.prepare_context(results, opts)

      if indexed == [] do
        assert quality == :none
      else
        assert quality == :good
      end
    end
  end
end
