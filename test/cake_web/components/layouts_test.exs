defmodule CakeWeb.LayoutsTest do
  @moduledoc """
  What `CakeWeb.Layouts` says, to a screen reader and on the page (#374).

  The navbar's logo and the three theme buttons show no text, so what a
  screen reader announces for each is an attribute nothing visible checks.

  The flash messages keep the wording they had before the Phoenix 1.8
  layouts were adopted: #374 changes no visible text, and the generator's
  1.8 `flash_group/1` words three of these differently.
  """

  use CakeWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias CakeWeb.Layouts

  defp app_layout do
    assigns = %{}

    ~H"""
    <Layouts.app flash={%{}}>content</Layouts.app>
    """
    |> rendered_to_string()
    |> Floki.parse_fragment!()
  end

  test "each theme button names the theme it selects" do
    names =
      for button <- Floki.find(app_layout(), "button[data-phx-theme]"), into: %{} do
        {attribute(button, "data-phx-theme"), attribute(button, "aria-label")}
      end

    assert names == %{
             "system" => "System theme",
             "light" => "Light theme",
             "dark" => "Dark theme"
           }
  end

  test "every image in the app layout has alternative text" do
    images = Floki.find(app_layout(), "img")

    assert images != []
    assert Enum.all?(images, &(attribute(&1, "alt") not in [nil, ""]))
  end

  describe "flash_group/1" do
    test "an info flash is titled Success! and an error flash Error!" do
      html = flash_group(%{"info" => "Password updated", "error" => "Invalid token"})

      assert flash_text(html, "#flash-info") == "Success! Password updated"
      assert flash_text(html, "#flash-error") == "Error! Invalid token"
    end

    test "a flash that is not set is not rendered" do
      html = flash_group(%{})

      assert Floki.find(html, "#flash-info") == []
      assert Floki.find(html, "#flash-error") == []
    end

    test "the two connection notices keep their wording" do
      html = flash_group(%{})

      assert flash_text(html, "#client-error") ==
               "We can't find the internet Attempting to reconnect"

      assert flash_text(html, "#server-error") ==
               "Something went wrong! Hang in there while we get back on track"
    end
  end

  defp flash_group(flash) do
    (&Layouts.flash_group/1)
    |> render_component(flash: flash)
    |> Floki.parse_fragment!()
  end

  # The text of one flash, with runs of whitespace collapsed.
  defp flash_text(html, selector) do
    html
    |> Floki.find(selector)
    |> Floki.text(sep: " ")
    |> String.split()
    |> Enum.join(" ")
  end

  defp attribute(element, name), do: element |> Floki.attribute(name) |> List.first()
end
