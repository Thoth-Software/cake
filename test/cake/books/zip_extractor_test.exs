defmodule Cake.Books.ZipExtractorTest do
  use ExUnit.Case, async: true

  import Cake.ZipFixtures

  alias Cake.Books.ZipExtractor

  defp make_zip(entries), do: zip_binary(entries)

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

    test "extracts stored (uncompressed) PDF entries" do
      zip = zip_binary([{"stored.pdf", "stored-content"}], compress: [])

      assert {:ok, [{"stored.pdf", "stored-content"}]} = ZipExtractor.extract_pdfs(zip)
    end

    test "extracts entries whose CRC and sizes trail the data in a descriptor" do
      zip = streamed_zip_binary([{"a.pdf", "content-a"}, {"notes.txt", "text"}, {"b.pdf", ""}])

      assert {:ok, [{"a.pdf", "content-a"}, {"b.pdf", ""}]} = ZipExtractor.extract_pdfs(zip)
    end
  end

  describe "extract_pdfs/2 expansion limits" do
    test "rejects an archive whose PDF entries declare more than the cap, before inflating" do
      # The entry is 16 bytes; only its central-directory record claims 2 MB.
      zip =
        [{"a.pdf", "sixteen-bytes!!!"}]
        |> zip_binary()
        |> forge_declared_size("a.pdf", 2_000_000)

      assert {:error, {:too_large, 2_000_000, 1_000_000}} =
               ZipExtractor.extract_pdfs(zip, max_expanded_bytes: 1_000_000)
    end

    test "sums the declared sizes of every PDF entry against the cap" do
      zip =
        zip_binary([{"a.pdf", String.duplicate("a", 600)}, {"b.pdf", String.duplicate("b", 600)}])

      assert {:error, {:too_large, 1_200, 1_000}} =
               ZipExtractor.extract_pdfs(zip, max_expanded_bytes: 1_000)
    end

    test "accepts PDF entries whose declared sizes sum to exactly the cap" do
      zip =
        zip_binary([{"a.pdf", String.duplicate("a", 500)}, {"b.pdf", String.duplicate("b", 500)}])

      assert {:ok, [_, _]} = ZipExtractor.extract_pdfs(zip, max_expanded_bytes: 1_000)
    end

    test "non-PDF entries do not count against the cap and are never returned" do
      zip =
        zip_binary([
          {"huge.bin", :binary.copy(<<0>>, 100_000)},
          {"__MACOSX/._small.pdf", :binary.copy(<<0>>, 100_000)},
          {"small.pdf", "pdf-content"}
        ])

      assert {:ok, [{"small.pdf", "pdf-content"}]} =
               ZipExtractor.extract_pdfs(zip, max_expanded_bytes: 1_000)
    end

    test "rejects an archive with more entries than the entry limit, PDF or not" do
      zip = zip_binary([{"a.pdf", "a"}, {"b.txt", "b"}, {"c.png", "c"}, {"d.pdf", "d"}])

      assert {:error, {:too_many_entries, 4, 3}} = ZipExtractor.extract_pdfs(zip, max_entries: 3)
      assert {:ok, [_, _]} = ZipExtractor.extract_pdfs(zip, max_entries: 4)
    end

    test "stops inflating an entry that expands past the size the archive declares for it" do
      # 1 MB of zeros deflates to ~1 KB; the central directory claims 10 bytes,
      # so the declared-size pre-check passes and only the bounded inflate
      # can catch it.
      zip =
        [{"bomb.pdf", :binary.copy(<<0>>, 1_000_000)}]
        |> zip_binary()
        |> forge_declared_size("bomb.pdf", 10)

      assert {:error, {:size_mismatch, "bomb.pdf"}} =
               ZipExtractor.extract_pdfs(zip, max_expanded_bytes: 1_000)
    end

    test "rejects an entry that inflates to less than the size it declares" do
      zip = [{"short.pdf", "short"}] |> zip_binary() |> forge_declared_size("short.pdf", 50)

      assert {:error, {:size_mismatch, "short.pdf"}} = ZipExtractor.extract_pdfs(zip)
    end

    test "rejects an entry whose content does not match its CRC" do
      zip = [{"a.pdf", "content"}] |> zip_binary() |> forge_local_crc("a.pdf", 0xDEADBEEF)

      assert {:error, {:bad_crc, "a.pdf"}} = ZipExtractor.extract_pdfs(zip)
    end

    test "rejects an entry compressed with a method other than store or deflate" do
      # 12 is bzip2.
      zip = [{"a.pdf", "content"}] |> zip_binary() |> forge_compression_method("a.pdf", 12)

      assert {:error, {:unsupported_compression, "a.pdf"}} = ZipExtractor.extract_pdfs(zip)
    end

    test "rejects an entry whose deflate stream is corrupt" do
      # Method 8 over data that was stored raw: not a valid deflate stream.
      zip =
        [{"a.pdf", :binary.copy(<<0xFF>>, 64)}]
        |> zip_binary(compress: [])
        |> forge_compression_method("a.pdf", 8)

      assert {:error, {:corrupt_entry, "a.pdf"}} = ZipExtractor.extract_pdfs(zip)
    end

    test "reads its limits from the application environment by default" do
      cap = Application.fetch_env!(:cake, :max_zip_expanded_bytes)
      declared = cap + 1

      zip = [{"a.pdf", "content"}] |> zip_binary() |> forge_declared_size("a.pdf", declared)

      assert {:error, {:too_large, ^declared, ^cap}} = ZipExtractor.extract_pdfs(zip)
      assert is_integer(Application.fetch_env!(:cake, :max_zip_entries))
    end
  end
end
