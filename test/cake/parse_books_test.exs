defmodule Cake.ParseBooksTest do
  @moduledoc """
  The contract of the Rustler NIF `Cake.ParseBooks.extract_pdf/1`, pinned
  against the fixture PDFs under `test/support/fixtures/pdfs/` (#246). The
  fixtures README records the exact text lopdf extracts from every page.

  Tagged `:integration`: the suite needs the compiled `parsebooks` crate and
  runs in the merge gate (`mix test --only integration`), not the pre-push
  hot path.
  """

  use ExUnit.Case, async: true

  import Cake.PdfFixtures

  alias Cake.Books.PageContent
  alias Cake.Books.PdfExtraction
  alias Cake.Books.SkippedPage
  alias Cake.ParseBooks

  @moduletag :integration

  defp extract!(name) do
    {:ok, %PdfExtraction{} = extraction} = ParseBooks.extract_pdf(fixture_binary(name))
    extraction
  end

  describe "extract_pdf/1 on a well-formed PDF" do
    test "returns every page's text in page order" do
      # `page_number` is the page's 1-based position in the page tree — the
      # number a PDF viewer shows — not a printed manuscript page number.
      # #87 proposes an additive `manuscript_page` for the latter; this
      # pins the viewer index as the meaning of `page_number`.
      assert %PdfExtraction{pages: pages, skipped: []} = extract!(:multi_page)

      assert pages == [
               %PageContent{
                 page_number: 1,
                 text: "Cake Fixture Book\nChapter one begins on the first page.\n"
               },
               %PageContent{
                 page_number: 2,
                 text: "The second page continues the story.\nIt has two lines of text.\n"
               },
               %PageContent{page_number: 3, text: "The third page ends the book.\n"}
             ]
    end

    test "decodes into the PdfExtraction and PageContent struct shapes" do
      extraction = extract!(:multi_page)

      assert %PdfExtraction{pages: pages, skipped: skipped, title: title} = extraction
      assert extraction |> Map.keys() |> Enum.sort() == [:__struct__, :pages, :skipped, :title]
      assert is_list(pages) and is_list(skipped)
      assert title == "Cake Fixture Book"

      for page <- pages do
        assert %PageContent{page_number: page_number, text: text} = page
        assert page |> Map.keys() |> Enum.sort() == [:__struct__, :page_number, :text]
        assert is_integer(page_number) and page_number >= 1
        # Postgres text columns reject invalid UTF-8; the NIF must hand
        # back valid strings, never raw bytes.
        assert is_binary(text) and String.valid?(text)
      end
    end

    test "reads the metadata title from the Info dictionary" do
      assert %PdfExtraction{title: "Cake Fixture Book"} = extract!(:multi_page)
    end

    test "returns a nil title when the PDF has no Info dictionary" do
      assert %PdfExtraction{title: nil, pages: [_, _]} = extract!(:no_title)
    end

    test "passes a junk metadata title through unchanged (#86)" do
      # The NIF reports what the file says. Whether the pipeline should
      # trust a junk-but-present title over the first-page heading is #86's
      # question and is pinned at the pipeline level, not here.
      assert %PdfExtraction{title: "Rev. 6/07"} = extract!(:junk_title)
    end

    test "returns pages with no text as pages with empty text, not as skipped" do
      assert %PdfExtraction{pages: pages, skipped: [], title: nil} = extract!(:blank_pages)

      assert Enum.map(pages, &{&1.page_number, &1.text}) == [
               {1, ""},
               {2, "Text on page two.\n"},
               {3, ""},
               {4, "Text on page four.\n"}
             ]
    end
  end

  describe "extract_pdf/1 on partially extractable input" do
    test "reports the page that fails extraction in skipped and keeps the rest" do
      assert %PdfExtraction{pages: pages, skipped: skipped, title: "Partially Extractable"} =
               extract!(:skipped_page)

      assert Enum.map(pages, &{&1.page_number, &1.text}) == [
               {1, "Before the broken page.\n"},
               {3, "After the broken page.\n"}
             ]

      assert [%SkippedPage{page_number: 2, reason: reason}] = skipped
      assert skipped |> hd() |> Map.keys() |> Enum.sort() == [:__struct__, :page_number, :reason]
      assert reason =~ "missing font operand"
    end
  end

  describe "extract_pdf/1 on a binary that is not a loadable PDF" do
    test "returns {:error, reason} for a truncated PDF instead of crashing the NIF" do
      assert {:error, reason} = ParseBooks.extract_pdf(fixture_binary(:truncated))
      assert reason =~ "PDF load failed"
    end

    test "returns {:error, reason} for an empty binary" do
      assert {:error, reason} = ParseBooks.extract_pdf("")
      assert reason =~ "PDF load failed"
    end

    test "returns {:error, reason} for bytes with no PDF header" do
      assert {:error, reason} = ParseBooks.extract_pdf(<<0, 255, 1, 2, 3>>)
      assert reason =~ "invalid file header"
    end
  end
end
