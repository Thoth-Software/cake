defmodule Cake.Books.Pdf.PipelineIntegrationTest do
  @moduledoc """
  `Cake.Books.Pdf.Pipeline.parse/1` over real fixture PDFs through the real
  NIF (#246): the `{ParsedBook, [Chunk]}` pair it builds, unpersisted. The
  fixtures README under `test/support/fixtures/pdfs/` records the text each
  page extracts to; the expected counts below are derived from it.

  Tagged `:integration` with the NIF contract tests: merge gate only
  (`mix test --only integration`). `parse/1` never touches Postgres, so
  the tests are async and need no sandbox.
  """

  use ExUnit.Case, async: true

  import Cake.PdfFixtures
  import ExUnit.CaptureLog

  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook

  @moduletag :integration

  defp chunk_indices(chunks), do: Enum.map(chunks, & &1.chunk_index)
  defp page_numbers(chunks), do: Enum.map(chunks, & &1.page_number)

  describe "chunks" do
    test "one chunk per page, indexed densely from 0 in page order" do
      {%ParsedBook{}, chunks} = parse_fixture(:multi_page)

      assert Enum.all?(chunks, &match?(%Chunk{}, &1))
      assert chunk_indices(chunks) == [0, 1, 2]
      # `page_number` is the viewer's 1-based page index, the same number
      # the NIF reports; #87 proposes an additive manuscript_page field and
      # would not change this.
      assert page_numbers(chunks) == [1, 2, 3]

      assert Enum.map(chunks, & &1.text) == [
               "Cake Fixture Book\nChapter one begins on the first page.\n",
               "The second page continues the story.\nIt has two lines of text.\n",
               "The third page ends the book.\n"
             ]
    end

    test "rejects blank pages before assigning chunk_index, so indices stay dense" do
      # build_chunks/1 invariant: a hole in chunk_index breaks neighbor
      # expansion and page-range queries downstream. Pages 1 and 3 of the
      # fixture have no text; the surviving chunks must be 0 and 1, still
      # carrying their real page numbers.
      {%ParsedBook{}, chunks} = parse_fixture(:blank_pages)

      assert chunk_indices(chunks) == [0, 1]
      assert page_numbers(chunks) == [2, 4]
      assert Enum.map(chunks, & &1.text) == ["Text on page two.\n", "Text on page four.\n"]
    end

    test "counts each chunk's words and characters from its page text" do
      {%ParsedBook{}, [first | _]} = parse_fixture(:multi_page)

      assert %Chunk{word_count: 10, char_count: 56} = first
    end

    test "chunks the pages around a skipped page, densely, and warns about the skip" do
      log =
        capture_log(fn ->
          {%ParsedBook{}, chunks} = parse_fixture(:skipped_page)

          assert chunk_indices(chunks) == [0, 1]
          assert page_numbers(chunks) == [1, 3]

          assert Enum.map(chunks, & &1.text) == [
                   "Before the broken page.\n",
                   "After the broken page.\n"
                 ]
        end)

      assert log =~ "skipped_page.pdf: skipped pages 2"
    end
  end

  describe "title fallback chain" do
    test "uses the metadata title when the PDF has one" do
      {%ParsedBook{title: "Cake Fixture Book"}, _chunks} = parse_fixture(:multi_page)
    end

    test "falls back to the first line of the first page without a metadata title" do
      {%ParsedBook{title: "Title From The First Line"}, _chunks} = parse_fixture(:no_title)
    end

    test "falls back to the filename when the first page has no text either" do
      {%ParsedBook{title: "blank_pages"}, _chunks} = parse_fixture(:blank_pages)
    end

    test "honours a junk metadata title over the first-page heading (#86)" do
      # Pins the current chain: a present, non-blank metadata title wins
      # even when it is a revision stamp and the first page carries a real
      # heading ("Sand Filter Installation Manual"). That is the #86
      # symptom; if #86 decides the chain should distrust such titles, this
      # is the assertion to change.
      {%ParsedBook{title: "Rev. 6/07"}, _chunks} = parse_fixture(:junk_title)
    end
  end

  describe "book metadata" do
    test "records the source key, format, hash, size, page and word counts" do
      binary = fixture_binary(:multi_page)
      {%ParsedBook{} = book, _chunks} = parse_fixture(:multi_page)

      assert book.source_file_path == fixture_path(:multi_page)
      assert book.source_format == "pdf"
      assert book.file_hash == Base.encode16(:crypto.hash(:sha256, binary), case: :lower)
      assert book.file_size == byte_size(binary)
      assert book.total_pages == 3
      assert book.word_count == 28
      assert book.embedding_status == :pending
      assert %DateTime{microsecond: {0, 0}} = book.parsed_at
    end

    test "counts blank pages in total_pages but not in word_count" do
      {%ParsedBook{} = book, _chunks} = parse_fixture(:blank_pages)

      assert book.total_pages == 4
      assert book.word_count == 8
    end
  end
end
