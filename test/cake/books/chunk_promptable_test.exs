defmodule Cake.Books.ChunkPromptableTest do
  use ExUnit.Case, async: true

  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Promptable

  defp chunk(attrs) do
    book_attrs =
      Map.merge(
        %{title: "RO-400 Manual", source_file_path: "/path/to/book.pdf"},
        Map.get(attrs, :parsed_book_attrs, %{})
      )

    defaults = %{
      text: "Replace the filter every 6 months.",
      page_number: 42,
      chunk_index: 0,
      section_title: "Maintenance",
      word_count: 7,
      char_count: 36,
      parsed_book: struct(ParsedBook, book_attrs)
    }

    struct(Chunk, Map.merge(defaults, Map.delete(attrs, :parsed_book_attrs)))
  end

  describe "Cake.Promptable implementation" do
    test "returns the current format_chunk/1 output minus the [N] index prefix" do
      c = chunk(%{})

      expected =
        """
        Book: RO-400 Manual | Page: 42
        Section: Maintenance

        Replace the filter every 6 months.\
        """

      assert Promptable.prompt_context(c) == expected
    end

    test "handles nil page_number (matches current format_chunk behavior)" do
      c = chunk(%{page_number: nil})

      expected =
        """
        Book: RO-400 Manual | Page:\s
        Section: Maintenance

        Replace the filter every 6 months.\
        """

      assert Promptable.prompt_context(c) == expected
    end

    test "renders nil section_title as (none) (matches current format_chunk behavior)" do
      c = chunk(%{section_title: nil})

      expected =
        """
        Book: RO-400 Manual | Page: 42
        Section: (none)

        Replace the filter every 6 months.\
        """

      assert Promptable.prompt_context(c) == expected
    end

    test "returns a String" do
      assert is_binary(Promptable.prompt_context(chunk(%{})))
    end
  end
end
