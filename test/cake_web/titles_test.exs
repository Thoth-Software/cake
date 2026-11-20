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

    test "spells out the page of a citation label" do
      assert Titles.display("Plan, p. 5") == "Plan, PDF page 5"
    end

    test "trims the ends" do
      assert Titles.display("  Plan  ") == "Plan"
    end

    test "calls a missing title Untitled, and leaves an emptied one empty" do
      assert Titles.display(nil) == "Untitled"
      assert Titles.display("\u0001") == ""
    end

    property "never shows a control or replacement character, nor space at either end" do
      check all(title <- string(:printable), junk <- string([0..0x1F, 0xFFFD])) do
        shown = Titles.display(junk <> title <> junk)

        refute shown =~ ~r/[\x{fffd}\x{0}-\x{1f}]/u
        assert shown == String.trim(shown)
      end
    end
  end
end
