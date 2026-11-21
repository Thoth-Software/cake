defmodule CakeWeb.TitlesPropertyTest do
  @moduledoc """
  Properties of `CakeWeb.Titles` (#380): whatever a title holds, what is
  displayed has no control or replacement character, is trimmed, and has
  something in it to see; and a citation label differs from a title only in
  how its page is written.

  Example tests are in `test/cake_web/titles_test.exs`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CakeWeb.Titles

  # Characters a title can carry that show nothing: the C0 and C1 controls
  # and DEL, the replacement character, and some zero-width and bidi marks.
  defp invisible do
    string([0..0x1F, 0x7F..0x9F, 0xFFFD, 0x200B, 0x200E, 0x2060])
  end

  describe "display/1" do
    property "never shows a control or replacement character, nor space at either end" do
      check all(title <- string(:printable), junk <- invisible()) do
        shown = Titles.display(junk <> title <> junk)

        refute shown =~ ~r/[\p{Cc}\x{fffd}]/u
        assert shown == String.trim(shown)
      end
    end

    property "always shows something that can be seen" do
      check all(title <- string(:printable), junk <- invisible()) do
        shown = Titles.display(junk <> title <> junk)

        assert shown =~ ~r/[^\p{Cc}\p{Cf}\p{Z}\s]/u
      end
    end

    property "is Untitled for a title of invisible characters and spaces alone" do
      check all(junk <- invisible(), spaces <- string([?\s, 0xA0])) do
        assert Titles.display(junk <> spaces <> junk) == "Untitled"
      end
    end
  end

  describe "display_citation_label/1" do
    property "differs from display/1 only in how a page is written" do
      check all(title <- string(:printable)) do
        assert Titles.display_citation_label(title) ==
                 String.replace(Titles.display(title), ~r/, p\. (\d+)/, ", PDF page \\1")
      end
    end
  end
end
