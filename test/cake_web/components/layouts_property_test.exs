defmodule CakeWeb.LayoutsPropertyTest do
  @moduledoc """
  Properties of the app shell's links (#375): whatever the username, the
  role alone decides which pages the shell links to.

  The shell is rendered from a `User` struct, with no request and no
  database. Example tests are in `CakeWeb.LayoutsTest`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias Cake.Accounts.User
  alias CakeWeb.Layouts

  @member_links ["/chat", "/upload", "/search"]
  @admin_links ["/chat", "/upload", "/search", "/admin"]

  # A username as `Cake.Accounts.User` accepts it.
  defp username do
    string([?a..?z, ?A..?Z, ?0..?9, ?_, ?., ?-], min_length: 3, max_length: 32)
  end

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

  defp links(html, selector), do: html |> Floki.find(selector <> " a") |> Floki.attribute("href")

  property "the shell links to the admin area exactly when the user is an admin" do
    check all(username <- username(), role <- member_of([:member, :admin])) do
      html = app_layout(%User{username: username, role: role})

      expected = if role == :admin, do: @admin_links, else: @member_links

      assert links(html, "#main-nav") == expected
      assert "/admin" in links(html, "header") == (role == :admin)
    end
  end

  property "the collapsed menu holds the same links as the top bar" do
    check all(username <- username(), role <- member_of([:member, :admin])) do
      html = app_layout(%User{username: username, role: role})

      assert links(html, "#mobile-nav") == links(html, "#main-nav")
    end
  end

  property "the user menu shows the username as it is" do
    check all(username <- username(), role <- member_of([:member, :admin])) do
      html = app_layout(%User{username: username, role: role})

      assert html |> Floki.find("#user-menu-username") |> Floki.text() |> String.trim() ==
               username
    end
  end

  property "on any of its pages the shell links to every other page and not to that one" do
    pages = %{chat: "/chat", upload: "/upload", search: "/search", admin: "/admin"}

    check all(
            username <- username(),
            role <- member_of([:member, :admin]),
            page <-
              member_of(if(role == :admin, do: Map.keys(pages), else: [:chat, :upload, :search]))
          ) do
      html = app_layout(%User{username: username, role: role}, page)
      all_links = if role == :admin, do: @admin_links, else: @member_links

      for nav <- ["#main-nav", "#mobile-nav"] do
        assert links(html, nav) == all_links -- [pages[page]]
        assert length(Floki.find(html, ~s|#{nav} [aria-current="page"]|)) == 1
      end
    end
  end
end
