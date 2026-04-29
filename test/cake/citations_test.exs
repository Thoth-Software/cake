defmodule Cake.CitationsTest do
  use Cake.DataCase, async: true

  import ExUnit.CaptureLog

  alias Cake.Citations

  @meta_1 %{
    id: {"programming_elixir.pdf", 10},
    label: "Programming Elixir, p. 42 — Enum",
    preview: "The Enum module provides a set of algorithms to work with enumerables.",
    source_ref: "assets/static/programming_elixir.pdf",
    extras: %{
      book_title: "Programming Elixir",
      page_number: 42,
      section_title: "Enum",
      chunk_index: 10
    }
  }

  @meta_2 %{
    id: {"programming_elixir.pdf", 15},
    label: "Programming Elixir, p. 55 — Streams",
    preview: "Streams are lazy enumerables that allow you to compose operations.",
    source_ref: "assets/static/programming_elixir.pdf",
    extras: %{
      book_title: "Programming Elixir",
      page_number: 55,
      section_title: "Streams",
      chunk_index: 15
    }
  }

  @meta_3 %{
    id: {"elixir_in_action.pdf", 40},
    label: "Elixir in Action, p. 101 — Tasks",
    preview:
      "Tasks are processes meant to execute one particular action throughout their lifetime.",
    source_ref: "assets/static/elixir_in_action.pdf",
    extras: %{
      book_title: "Elixir in Action",
      page_number: 101,
      section_title: "Tasks",
      chunk_index: 40
    }
  }

  @chunk_map %{1 => @meta_1, 2 => @meta_2, 3 => @meta_3}

  describe "extract/2" do
    test "returns a two-tuple of {citations, hallucinated}" do
      assert {citations, hallucinated} = Citations.extract("Use [1]", @chunk_map)
      assert is_list(citations)
      assert is_list(hallucinated)
    end

    test "valid citations preserve first-appearance order" do
      {citations, _} = Citations.extract("First [3] then [1] and [3] again.", @chunk_map)

      assert Enum.map(citations, & &1.index) == [3, 1]
    end

    test "deduplicates repeated indices" do
      {citations, _} = Citations.extract("Use Enum [1] and also Enum again [1].", @chunk_map)

      assert length(citations) == 1
      assert hd(citations).index == 1
    end

    test "hallucinated indices are returned in the second element" do
      {_, hallucinated} =
        Citations.extract("This is supported [1] and also [99] and [42].", @chunk_map)

      assert hallucinated == [99, 42]
    end

    test "hallucinated indices are logged at warn level" do
      log = capture_log(fn -> Citations.extract("cite [99]", @chunk_map) end)

      assert log =~ "Citation [99] not found in chunk_map"
    end

    test "each citation carries the Citable metadata shape" do
      {citations, _} = Citations.extract("Use [1]", @chunk_map)
      [citation] = citations

      assert citation |> Map.keys() |> Enum.sort() == [:index, :metadata]

      assert citation.metadata |> Map.keys() |> Enum.sort() ==
               [:extras, :id, :label, :preview, :source_ref]
    end

    test "empty input yields empty citations and empty hallucinations" do
      assert Citations.extract("", %{}) == {[], []}
    end

    test "text with only hallucinated indices yields empty citations" do
      {citations, hallucinated} = Citations.extract("cite [42] and [99]", @chunk_map)

      assert citations == []
      assert hallucinated == [42, 99]
    end

    test "text with no citation markers yields empty citations and empty hallucinations" do
      assert Citations.extract("There are no markers here.", @chunk_map) == {[], []}
    end
  end

  describe "integration with Books.Chunk Citable impl" do
    import Cake.BooksFixtures

    test "extracts citations through Responses.build_citation_map + Cake.Citable" do
      chunk =
        Repo.preload(
          chunk_fixture(%{page_number: 12, section_title: "Chapter One"}),
          :parsed_book
        )

      indexed = [{1, {chunk, %{os_score: 1.0}}}]
      chunk_map = Cake.Responses.build_citation_map(indexed)

      {citations, hallucinated} = Citations.extract("See [1].", chunk_map)

      assert hallucinated == []
      [citation] = citations
      assert citation.index == 1
      assert citation.metadata.id == chunk.id
      assert citation.metadata.preview == String.slice(chunk.text, 0, 200)
      assert citation.metadata.source_ref == chunk.parsed_book.source_file_path
    end
  end
end
