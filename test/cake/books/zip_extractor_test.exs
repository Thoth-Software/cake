defmodule Cake.Books.ZipExtractorTest do
  use ExUnit.Case, async: true

  alias Cake.Books.ZipExtractor

  defp make_zip(entries) do
    charlist_entries = Enum.map(entries, fn {name, content} -> {~c"#{name}", content} end)
    {:ok, {~c"test.zip", zip_binary}} = :zip.create(~c"test.zip", charlist_entries, [:memory])
    zip_binary
  end

  describe "extract_pdfs/1" do
    test "extracts PDF files from a flat ZIP" do
      zip = make_zip([{"doc.pdf", "pdf-content"}, {"other.pdf", "other-content"}])

      assert {:ok, pdfs} = ZipExtractor.extract_pdfs(zip)
      assert length(pdfs) == 2
      assert {"doc.pdf", "pdf-content"} in pdfs
      assert {"other.pdf", "other-content"} in pdfs
    end

    test "extracts PDF files from nested directories" do
      zip =
        make_zip([
          {"level1/doc.pdf", "content-1"},
          {"level1/level2/doc.pdf", "content-2"},
          {"level1/level2/level3/deep.pdf", "content-3"}
        ])

      assert {:ok, pdfs} = ZipExtractor.extract_pdfs(zip)
      assert length(pdfs) == 3
      assert {"level1/doc.pdf", "content-1"} in pdfs
      assert {"level1/level2/doc.pdf", "content-2"} in pdfs
      assert {"level1/level2/level3/deep.pdf", "content-3"} in pdfs
    end

    test "ignores non-PDF files" do
      zip =
        make_zip([
          {"document.pdf", "pdf-content"},
          {"image.png", "png-content"},
          {"readme.txt", "text-content"},
          {"data.csv", "csv-content"}
        ])

      assert {:ok, pdfs} = ZipExtractor.extract_pdfs(zip)
      assert length(pdfs) == 1
      assert {"document.pdf", "pdf-content"} in pdfs
    end

    test "ignores __MACOSX resource fork entries" do
      zip =
        make_zip([
          {"document.pdf", "pdf-content"},
          {"__MACOSX/._document.pdf", "resource-fork"},
          {"__MACOSX/subdir/._other.pdf", "resource-fork-2"}
        ])

      assert {:ok, pdfs} = ZipExtractor.extract_pdfs(zip)
      assert length(pdfs) == 1
      assert {"document.pdf", "pdf-content"} in pdfs
    end

    test "handles case-insensitive .PDF extension" do
      zip =
        make_zip([
          {"upper.PDF", "content-1"},
          {"mixed.Pdf", "content-2"},
          {"lower.pdf", "content-3"}
        ])

      assert {:ok, pdfs} = ZipExtractor.extract_pdfs(zip)
      assert length(pdfs) == 3
    end

    test "returns empty list for ZIP with no PDFs" do
      zip = make_zip([{"readme.txt", "text"}, {"image.jpg", "image"}])

      assert {:ok, []} = ZipExtractor.extract_pdfs(zip)
    end

    test "returns error for corrupt binary" do
      assert {:error, _reason} = ZipExtractor.extract_pdfs("not-a-zip")
    end
  end
end
