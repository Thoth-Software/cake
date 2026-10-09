defmodule Cake.Books.ZipExtractorTest do
  @moduledoc """
  Readable anchors for `Cake.Books.ZipExtractor.extract_pdfs/1`. The filter
  itself (nesting, non-PDF entries, the macOS resource fork, case-insensitive
  extensions, empty results) is pinned by the round-trip property in
  `zip_extractor_property_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Cake.Books.ZipExtractor

  defp make_zip(entries) do
    charlist_entries = Enum.map(entries, fn {name, content} -> {~c"#{name}", content} end)
    {:ok, {~c"test.zip", zip_binary}} = :zip.create(~c"test.zip", charlist_entries, [:memory])
    zip_binary
  end

  describe "extract_pdfs/1" do
    test "extracts the PDF entries of a mixed archive as {name, bytes} pairs" do
      zip =
        make_zip([
          {"doc.pdf", "pdf-content"},
          {"nested/other.PDF", "other-content"},
          {"readme.txt", "text-content"},
          {"__MACOSX/._doc.pdf", "resource-fork"}
        ])

      assert {:ok, pdfs} = ZipExtractor.extract_pdfs(zip)

      assert Enum.sort(pdfs) == [
               {"doc.pdf", "pdf-content"},
               {"nested/other.PDF", "other-content"}
             ]
    end

    test "returns error for corrupt binary" do
      assert {:error, _reason} = ZipExtractor.extract_pdfs("not-a-zip")
    end
  end
end
