defmodule Cake.CitationsTest do
  use ExUnit.Case, async: true

  alias Cake.Citations

  @chunk_map %{
    1 => %{
      book_title: "Programming Elixir",
      section_title: "Enum",
      page_number: 42,
      chunk_index: 10,
      chunk_preview: "The Enum module provides a set of algorithms to work with enumerables.",
      source_file_path: "assets/static/programming_elixir.pdf"
    },
    2 => %{
      book_title: "Programming Elixir",
      section_title: "Streams",
      page_number: 55,
      chunk_index: 15,
      chunk_preview: "Streams are lazy enumerables that allow you to compose operations.",
      source_file_path: "assets/static/programming_elixir.pdf"
    },
    3 => %{
      book_title: "Elixir in Action",
      section_title: "Tasks",
      page_number: 101,
      chunk_index: 40,
      chunk_preview: "Tasks are processes meant to execute one particular action throughout their lifetime.",
      source_file_path: "assets/static/elixir_in_action.pdf"
    }
  }

  test "extracts valid citations from response text" do
    response = "Use Enum [1] and Tasks [3] for this."

    assert Citations.extract(response, @chunk_map) == [
             %{
               index: 1,
               book_title: "Programming Elixir",
               section_title: "Enum",
               page_number: 42,
               chunk_index: 10,
               chunk_preview: "The Enum module provides a set of algorithms to work with enumerables.",
               source_file_path: "assets/static/programming_elixir.pdf"
             },
             %{
               index: 3,
               book_title: "Elixir in Action",
               section_title: "Tasks",
               page_number: 101,
               chunk_index: 40,
               chunk_preview:
                 "Tasks are processes meant to execute one particular action throughout their lifetime.",
               source_file_path: "assets/static/elixir_in_action.pdf"
             }
           ]
  end

  test "drops hallucinated citations not in chunk_map" do
    response = "This is supported [1] and also [99]."

    assert Citations.extract(response, @chunk_map) == [
             %{
               index: 1,
               book_title: "Programming Elixir",
               section_title: "Enum",
               page_number: 42,
               chunk_index: 10,
               chunk_preview: "The Enum module provides a set of algorithms to work with enumerables.",
               source_file_path: "assets/static/programming_elixir.pdf"
             }
           ]
  end

  test "returns empty list when no citations present" do
    response = "There are no citations in this response."

    assert Citations.extract(response, @chunk_map) == []
  end

  test "deduplicates repeated citations" do
    response = "Use Enum [1] and also Enum again [1]."

    assert Citations.extract(response, @chunk_map) == [
             %{
               index: 1,
               book_title: "Programming Elixir",
               section_title: "Enum",
               page_number: 42,
               chunk_index: 10,
               chunk_preview: "The Enum module provides a set of algorithms to work with enumerables.",
               source_file_path: "assets/static/programming_elixir.pdf"
             }
           ]
  end
end
