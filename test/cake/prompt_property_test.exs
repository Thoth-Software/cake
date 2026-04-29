defmodule Cake.PromptPropertyTest do
  @moduledoc """
  Property tests for `Cake.Prompt.build/4`.

  Pins two structural invariants of the assembled prompt:

    1. Every chunk's `format_chunk/1` output appears in the system message
       with ordering preserved.
    2. The count of `[N]` markers in the system message equals
       `length(indexed_chunks)`.

  Example tests live in `prompt_test.exs`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cake.Prompt
  alias Cake.Test.ConvoChunk

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
      {%ConvoChunk{prompt_text: text}, %{relevance_score: score}}
    end
  end

  defp indexed_chunks do
    gen all(chunks <- list_of(scored_chunk(), min_length: 1, max_length: 8)) do
      chunks
      |> Enum.with_index(1)
      |> Enum.map(fn {sc, idx} -> {idx, sc} end)
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
end
