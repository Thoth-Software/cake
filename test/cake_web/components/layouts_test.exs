defmodule CakeWeb.LayoutsTest do
  @moduledoc """
  The app layout's controls have accessible names (#374).

  The navbar's logo and the three theme buttons show no text, so what a
  screen reader announces for each is an attribute nothing visible checks.
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

  defp attribute(element, name), do: element |> Floki.attribute(name) |> List.first()
end
