defmodule CakeWeb.LayoutsTest do
  @moduledoc """
  What `CakeWeb.Layouts` shows and says: the app shell's links for a
  visitor, a member and an admin (#375), the accessible names of its
  controls, and the wording of the flash messages (#374).

  The shell is rendered here on its own, from a `User` struct, with no
  request and no database. `CakeWeb.ShellTest` checks the same links on the
  real pages.

  The theme buttons and the menu button show no text, so what a screen
  reader announces for each is an attribute nothing visible checks.

  The flash messages keep the wording they had before the Phoenix 1.8
  layouts were adopted: the generator's 1.8 `flash_group/1` words three of
  them differently.
  """

  use CakeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Cake.Accounts.User
  alias CakeWeb.Layouts

  @member_links ["/chat", "/upload", "/search"]
  @admin_links ["/chat", "/upload", "/search", "/admin"]

  # The shell around an empty page, for a user or for `nil`, a visitor, and
  # for the page the shell is told it is on, if any.
  defp app_layout(current_user, current_page \\ nil) do
    (&Layouts.app/1)
    |> render_component(
      flash: %{},
      current_user: current_user,
      current_page: current_page,
      inner_block: []
    )
    |> Floki.parse_fragment!()
  end

  defp member, do: %User{username: "ada.lovelace", role: :member}
  defp admin, do: %User{username: "grace.hopper", role: :admin}

  # Where the links inside `selector` point, in page order.
  defp links(html, selector), do: html |> Floki.find(selector <> " a") |> Floki.attribute("href")

  defp text(html, selector), do: html |> Floki.find(selector) |> Floki.text() |> String.trim()

  describe "app/1, for a visitor" do
    test "links to no page, and offers to log in or register" do
      html = app_layout(nil)

      assert links(html, "#main-nav") == []
      assert Floki.find(html, "#mobile-nav") == []
      assert Floki.find(html, "#user-menu") == []
      assert Enum.sort(links(html, "#guest-menu")) == ["/users/log_in", "/users/register"]
    end
  end

  describe "app/1, for a member" do
    test "links to chat, upload and search, in that order, and not to the admin area" do
      html = app_layout(member())

      assert links(html, "#main-nav") == @member_links
      refute "/admin" in links(html, "header")
    end

    test "repeats the links in the menu they collapse into on a narrow screen" do
      html = app_layout(member())

      assert links(html, "#mobile-nav") == @member_links
    end

    test "has a user menu with the username, a link to change the password and one to log out" do
      html = app_layout(member())

      assert text(html, "#user-menu-username") == "ada.lovelace"
      assert links(html, "#user-menu") == ["/users/settings", "/users/log_out"]
      assert Floki.find(html, "#guest-menu") == []
    end

    test "logs out with a DELETE request" do
      [log_out] = Floki.find(app_layout(member()), ~s|#user-menu a[href="/users/log_out"]|)

      assert attribute(log_out, "data-method") == "delete"
    end
  end

  describe "app/1, for an admin" do
    test "links to what a member sees and then to the admin area, in both menus" do
      html = app_layout(admin())

      assert links(html, "#main-nav") == @admin_links
      assert links(html, "#mobile-nav") == @admin_links
    end
  end

  # A link to the page you are on would remount it and throw away what it
  # holds: on the chat, the conversation.
  describe "app/1, told which page it is on" do
    test "shows that page's entry as the current page, not as a link, in both menus" do
      for {page, label, path} <- [
            {:chat, "Chat", "/chat"},
            {:upload, "Upload", "/upload"},
            {:search, "Search", "/search"},
            {:admin, "Admin", "/admin"}
          ],
          nav <- ["#main-nav", "#mobile-nav"] do
        html = app_layout(admin(), page)

        assert links(html, nav) == @admin_links -- [path]
        assert [current] = Floki.find(html, ~s|#{nav} [aria-current="page"]|)
        assert current |> Floki.text() |> String.trim() == label
        assert attribute(current, "href") == nil
      end
    end

    test "keeps the entries in the same order" do
      html = app_layout(admin(), :upload)

      assert html |> Floki.find("#main-nav li") |> Enum.map(&String.trim(Floki.text(&1))) ==
               ["Chat", "Upload", "Search", "Admin"]
    end

    test "marks no entry when the page is not one of the shell's" do
      html = app_layout(admin())

      assert links(html, "#main-nav") == @admin_links
      assert Floki.find(html, ~s|header [aria-current="page"]|) == []
    end

    test "makes the product name inert on the chat, where it would otherwise link" do
      [on_chat] = Floki.find(app_layout(member(), :chat), "#brand")
      [elsewhere] = Floki.find(app_layout(member(), :search), "#brand")

      assert attribute(on_chat, "href") == nil
      assert on_chat |> Floki.text() |> String.trim() == "Cake"
      assert attribute(elsewhere, "href") == "/chat"
    end
  end

  describe "app/1, for anyone" do
    test "names the product; the name links home for a visitor and to the chat for a user" do
      for {current_user, href} <- [{nil, "/"}, {member(), "/chat"}, {admin(), "/chat"}] do
        [brand] = Floki.find(app_layout(current_user), "#brand")

        assert brand |> Floki.text() |> String.trim() == "Cake"
        assert attribute(brand, "href") == href
      end
    end

    test "puts the collapsed menu in a navigation landmark, as the top bar's links are" do
      html = app_layout(member())

      assert [_nav] = Floki.find(html, "nav:has(#mobile-nav)")
      assert [_nav] = Floki.find(html, "nav#main-nav")
      assert html |> Floki.find("header nav") |> Floki.attribute("aria-label") == ["Main", "Main"]
    end

    # What opens is a list of links, not a menu of commands, so neither
    # button may promise a screen reader a menu.
    test "neither menu button claims to open an ARIA menu" do
      triggers = Floki.find(app_layout(member()), ~s|header [role="button"]|)

      assert length(triggers) == 2
      assert Enum.all?(triggers, &(attribute(&1, "aria-haspopup") == nil))
    end

    test "each theme button names the theme it selects" do
      names =
        for button <- Floki.find(app_layout(nil), "button[data-phx-theme]"), into: %{} do
          {attribute(button, "data-phx-theme"), attribute(button, "aria-label")}
        end

      assert names == %{
               "system" => "System theme",
               "light" => "Light theme",
               "dark" => "Dark theme"
             }
    end

    test "the button that opens the collapsed menu has an accessible name" do
      [menu_button] = Floki.find(app_layout(member()), ~s|header [role="button"][aria-label]|)

      assert attribute(menu_button, "aria-label") == "Menu"
    end

    test "every image has alternative text" do
      for current_user <- [nil, member(), admin()] do
        images = Floki.find(app_layout(current_user), "img")

        assert Enum.all?(images, &(attribute(&1, "alt") not in [nil, ""]))
      end
    end
  end

  describe "app/1, the page column" do
    # The page is rendered into one column, `#page`. A form or a page of prose
    # reads best narrow; a table of records and the chat need the room (#392).
    defp page_column(attrs) do
      [column] =
        (&Layouts.app/1)
        |> render_component([flash: %{}, current_user: member(), inner_block: []] ++ attrs)
        |> Floki.parse_fragment!()
        |> Floki.find("#page")

      column
    end

    defp column_classes(column) do
      column |> Floki.attribute("class") |> Enum.flat_map(&String.split/1)
    end

    test "is narrow unless told otherwise" do
      column = page_column([])

      assert attribute(column, "data-width") == "narrow"
      assert "max-w-2xl" in column_classes(column)
    end

    test "is wide when asked" do
      column = page_column(width: :wide)

      assert attribute(column, "data-width") == "wide"
      assert "max-w-5xl" in column_classes(column)
      refute "max-w-2xl" in column_classes(column)
    end

    test "is narrow when asked" do
      assert attribute(page_column(width: :narrow), "data-width") == "narrow"
    end
  end

  describe "flash_group/1" do
    test "an info flash is titled Success! and an error flash Error!" do
      html = flash_group(%{"info" => "Password updated", "error" => "Invalid token"})

      assert flash_text(html, "#flash-info") == "Success! Password updated"
      assert flash_text(html, "#flash-error") == "Error! Invalid token"
    end

    # At the top the flash covered the account menu and the menu that opens
    # under it.
    test "a flash is placed in the bottom corner, clear of the top bar" do
      html = flash_group(%{"info" => "Password updated"})

      assert [classes] = Floki.attribute(html, "#flash-info", "class")
      assert "toast-bottom" in String.split(classes)
      refute "toast-top" in String.split(classes)
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
