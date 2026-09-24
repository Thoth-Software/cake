defmodule Mix.Tasks.Cake.Nif.CheckTest do
  @moduledoc """
  `mix cake.nif.check` (#250): the one-shot command the docker-compose smoke
  test runs inside the app container to prove the parsebooks NIF loads
  there. The unit tests drive `check/2` with a stub extractor; the
  `:integration` tests go through the real `Cake.ParseBooks.extract_pdf/1`
  over the fixture PDFs, like the rest of the NIF suite.
  """

  use ExUnit.Case, async: true

  import Cake.PdfFixtures

  alias Cake.Books.PageContent
  alias Cake.Books.PdfExtraction
  alias Cake.Books.SkippedPage
  alias Mix.Tasks.Cake.Nif.Check

  @extraction %PdfExtraction{
    title: "Cake Fixture Book",
    pages: [
      %PageContent{page_number: 1, text: "Cake Fixture Book\nChapter one begins.\n"},
      %PageContent{page_number: 3, text: "The third page ends the book.\n"}
    ],
    skipped: [%SkippedPage{page_number: 2, reason: "syntax error in content stream"}]
  }

  # A stub extractor that reports what it was handed back to the test process
  # before answering with `reply`.
  defp extractor(reply) do
    test_pid = self()

    fn binary ->
      send(test_pid, {:extract, binary})
      reply
    end
  end

  describe "check/2" do
    test "hands the file's bytes to the extractor and summarizes the extraction" do
      path = fixture_path(:multi_page)

      assert Check.check(path, extractor({:ok, @extraction})) ==
               {:ok,
                %{
                  path: path,
                  title: "Cake Fixture Book",
                  pages: 3,
                  extracted: 2,
                  skipped: 1,
                  words: 12
                }}

      assert_received {:extract, binary}
      assert binary == fixture_binary(:multi_page)
    end

    test "counts pages as extracted plus skipped, so a skipped page still counts" do
      extraction = %PdfExtraction{@extraction | pages: [], skipped: @extraction.skipped}

      assert {:ok, %{pages: 1, extracted: 0, skipped: 1, words: 0}} =
               Check.check(fixture_path(:multi_page), extractor({:ok, extraction}))
    end

    test "a missing title stays nil" do
      extraction = %PdfExtraction{@extraction | title: nil}

      assert {:ok, %{title: nil}} =
               Check.check(fixture_path(:multi_page), extractor({:ok, extraction}))
    end

    test "an unreadable path is an error and the extractor is never called" do
      path =
        Path.join(System.tmp_dir!(), "cake-nif-check-#{System.unique_integer([:positive])}.pdf")

      assert Check.check(path, extractor({:ok, @extraction})) ==
               {:error, "cannot read #{path}: no such file or directory"}

      refute_received {:extract, _binary}
    end

    test "an extractor error is reported with its reason" do
      assert Check.check(
               fixture_path(:multi_page),
               extractor({:error, "PDF load failed: failed parsing cross reference table"})
             ) ==
               {:error,
                "extraction failed: PDF load failed: failed parsing cross reference table"}
    end
  end

  describe "format/1" do
    test "renders the summary on one line, numbers and title included" do
      summary = %{
        path: "test/support/fixtures/pdfs/multi_page.pdf",
        title: "Cake Fixture Book",
        pages: 3,
        extracted: 2,
        skipped: 1,
        words: 12
      }

      assert Check.format(summary) ==
               ~s(NIF ok: test/support/fixtures/pdfs/multi_page.pdf: ) <>
                 ~s(title "Cake Fixture Book", 3 pages \(2 extracted, 1 skipped\), 12 words)
    end

    test "says so when there is no title" do
      summary = %{path: "x.pdf", title: nil, pages: 1, extracted: 1, skipped: 0, words: 2}

      assert Check.format(summary) ==
               "NIF ok: x.pdf: no title, 1 pages (1 extracted, 0 skipped), 2 words"
    end
  end

  describe "run/1" do
    test "rejects anything but exactly one path, before touching the project" do
      assert_raise Mix.Error, ~r/usage: mix cake\.nif\.check PATH/, fn -> Check.run([]) end

      assert_raise Mix.Error, ~r/usage: mix cake\.nif\.check PATH/, fn ->
        Check.run(["a.pdf", "b.pdf"])
      end
    end
  end

  describe "check/2 through the real NIF" do
    @describetag :integration

    test "extracts the happy-path fixture" do
      path = fixture_path(:multi_page)

      assert {:ok, %{path: ^path, title: "Cake Fixture Book", pages: 3, skipped: 0}} =
               Check.check(path, &Cake.ParseBooks.extract_pdf/1)
    end

    test "reports the truncated fixture as an error, not a crash" do
      assert {:error, "extraction failed: PDF load failed: " <> _rest} =
               Check.check(fixture_path(:truncated), &Cake.ParseBooks.extract_pdf/1)
    end
  end
end
