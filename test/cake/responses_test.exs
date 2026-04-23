defmodule Cake.ResponsesTest do
  use Cake.DataCase

  alias Cake.Responses
  alias Cake.Responses.Result

  describe "process/3" do
    import Cake.BooksFixtures

    setup do
      raw = chunk_fixture(%{page_number: 42, section_title: "Intro", chunk_index: 3})
      chunk = Repo.preload(raw, :parsed_book)
      indexed_chunks = [{1, {chunk, %{os_score: 1.0}}}]

      %{chunk: chunk, indexed_chunks: indexed_chunks}
    end

    test "returns a %Result{} struct", %{indexed_chunks: indexed_chunks} do
      assert %Result{} = Responses.process("Citing [1] here.", indexed_chunks)
    end

    test "raw_text equals the input", %{indexed_chunks: indexed_chunks} do
      text = "An answer with [1]."

      assert Responses.process(text, indexed_chunks).raw_text == text
    end

    test "final_text equals raw_text in Step 2", %{indexed_chunks: indexed_chunks} do
      text = "An answer with [1]."
      result = Responses.process(text, indexed_chunks)

      assert result.final_text == result.raw_text
    end

    test "chunk_map is a map keyed by positive integers", %{indexed_chunks: indexed_chunks} do
      chunk_map = Responses.process("hello [1]", indexed_chunks).chunk_map

      assert is_map(chunk_map)
      assert Enum.all?(Map.keys(chunk_map), &(is_integer(&1) and &1 > 0))
    end

    test "citations have old_index == new_index in Step 2", %{indexed_chunks: indexed_chunks} do
      result = Responses.process("Cite [1]", indexed_chunks)

      refute result.citations == []
      assert Enum.all?(result.citations, fn c -> c.old_index == c.new_index end)
    end

    test "each citation carries all seven Result.citation fields", %{
      indexed_chunks: indexed_chunks
    } do
      [citation | _] = Responses.process("Cite [1]", indexed_chunks).citations

      assert Enum.sort(Map.keys(citation)) ==
               [:extras, :id, :label, :new_index, :old_index, :preview, :source_ref]
    end

    test "media, actions, and warnings are empty in Step 2", %{indexed_chunks: indexed_chunks} do
      result = Responses.process("Cite [1]", indexed_chunks)

      assert result.media == []
      assert result.actions == []
      assert result.warnings == []
    end

    test "citations are empty when the raw text has no [N] references", %{
      indexed_chunks: indexed_chunks
    } do
      result = Responses.process("No citations here.", indexed_chunks)

      assert result.citations == []
    end
  end
end
