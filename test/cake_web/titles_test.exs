defmodule CakeWeb.TitlesTest do
  @moduledoc """
  `CakeWeb.Titles.display/1`: how a document's title is shown on every
  screen (#380). The function was `CakeWeb.ChatLive`'s own until the
  documents list needed the same one; these pin what it did there.
  Properties are in `test/cake_web/titles_property_test.exs`.
  """

  use ExUnit.Case, async: true

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

    # Characters that take no room and show nothing: a title made of them
    # looks as empty as an empty one.
    test "calls a title of invisible characters Untitled" do
      assert Titles.display("\u200B") == "Untitled"
      assert Titles.display("\u007F") == "Untitled"
      assert Titles.display("\u0085\u009F") == "Untitled"
      assert Titles.display("\u200E\u2060") == "Untitled"
      assert Titles.display(" \u00A0\u200B ") == "Untitled"
    end

    test "removes DEL and the C1 control characters, as the other control characters" do
      assert Titles.display("Annual\u007F Report\u0085") == "Annual Report"
    end

    # A zero-width joiner holds an emoji sequence together, and a zero-width
    # non-joiner is spelling in Persian: inside a title they are left alone.
    test "leaves invisible characters inside a title that has something to show" do
      assert Titles.display("Family \u{1F468}\u200D\u{1F469} album") ==
               "Family \u{1F468}\u200D\u{1F469} album"

      assert Titles.display("\u0645\u06CC\u200C\u062E\u0648\u0627\u0647\u0645") ==
               "\u0645\u06CC\u200C\u062E\u0648\u0627\u0647\u0645"
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
  end
end
