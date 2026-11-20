defmodule CakeWeb.TitlesTest do
  @moduledoc """
  `CakeWeb.Titles.display/1`: how a document's title is shown on every
  screen (#380). The function was `CakeWeb.ChatLive`'s own until the
  documents list needed the same one; these pin what it did there.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CakeWeb.Titles

  doctest CakeWeb.Titles

  describe "display/1" do
    test "leaves an ordinary title as it is" do
      assert Titles.display("Annual Report 2026") == "Annual Report 2026"
    end

    test "removes control characters and the replacement character" do
      assert Titles.display("Annual\u0000 Re\u0001port�\t") == "Annual Report"
    end

    test "drops Word's prefix, at the start only" do
      assert Titles.display("Microsoft Word - Plan.docx") == "Plan.docx"
      assert Titles.display("On Microsoft Word - a history") == "On Microsoft Word - a history"
    end

    # ", p. 5" in a stored title is part of the title. Only a citation label
    # carries a page that is to be spelled out (`display_citation_label/1`).
    test "leaves a title that mentions a page as it is" do
      assert Titles.display("Style Guide, p. 2 errata") == "Style Guide, p. 2 errata"
    end

    test "trims the ends" do
      assert Titles.display("  Plan  ") == "Plan"
    end

    # A title with nothing left to show would be a link nobody can click and
    # a heading nobody can read.
    test "calls a missing title Untitled, and one with nothing left in it too" do
      assert Titles.display(nil) == "Untitled"
      assert Titles.display("") == "Untitled"
      assert Titles.display("   ") == "Untitled"
      assert Titles.display("\u0001\uFFFD") == "Untitled"
      assert Titles.display("Microsoft Word - ") == "Untitled"
    end

    property "never shows a control or replacement character, nor space at either end, and is never empty" do
      check all(title <- string(:printable), junk <- string([0..0x1F, 0xFFFD])) do
        shown = Titles.display(junk <> title <> junk)

        refute shown =~ ~r/[\x{fffd}\x{0}-\x{1f}]/u
        assert shown == String.trim(shown)
        assert shown != ""
      end
    end
  end

  # A citation's label is a title followed by ", p. N", put together by the
  # citation: the chat shows it with the page spelled out.
  describe "display_citation_label/1" do
    test "spells out the page" do
      assert Titles.display_citation_label("Plan, p. 5") == "Plan, PDF page 5"
    end

    test "cleans the label as display/1 cleans a title" do
      assert Titles.display_citation_label("Microsoft Word - Plan\u0001.docx, p. 12 ") ==
               "Plan.docx, PDF page 12"
    end

    test "is display/1 for a label with no page, a missing one and an emptied one" do
      assert Titles.display_citation_label("Annual Report") == "Annual Report"
      assert Titles.display_citation_label(nil) == "Untitled"
      assert Titles.display_citation_label("\uFFFD") == "Untitled"
    end

    property "differs from display/1 only in how a page is written" do
      check all(title <- string(:printable)) do
        assert Titles.display_citation_label(title) ==
                 String.replace(Titles.display(title), ~r/, p\. (\d+)/, ", PDF page \\1")
      end
    end
  end
end
