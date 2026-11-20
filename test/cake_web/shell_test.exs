defmodule CakeWeb.ShellTest do
  @moduledoc """
  The app shell on the real pages (#375): which links a visitor, a member
  and an admin each see, and what each page is titled.

  `CakeWeb.LayoutsTest` checks the shell on its own. This checks that every
  page is inside it and hands it the user: a page that passed no user would
  show a member the visitor's links.

  Pages are requested, not mounted: the links and the title are in the
  first response.
  """

  use CakeWeb.ConnCase, async: true

  import Cake.AccountsFixtures

  @visitor_pages [
    "/",
    "/users/log_in",
    "/users/register",
    "/users/reset_password",
    "/users/confirm"
  ]
  @member_pages ["/chat", "/search", "/upload", "/users/settings"]
  @admin_pages ["/chat", "/search", "/upload", "/users/settings", "/admin"]

  @member_links ["/chat", "/upload", "/search"]
  @admin_links ["/chat", "/upload", "/search", "/admin"]

  @titles %{
    visitor: [
      {"/", "Cake"},
      {"/users/log_in", "Log in · Cake"},
      {"/users/register", "Register · Cake"},
      {"/users/reset_password", "Reset password · Cake"},
      {"/users/confirm", "Confirm account · Cake"}
    ],
    member: [
      {"/chat", "Chat · Cake"},
      {"/search", "Search · Cake"},
      {"/upload", "Upload · Cake"},
      {"/users/settings", "Account settings · Cake"}
    ],
    admin: [
      {"/admin", "Admin · Cake"}
    ]
  }

  defp page(conn, path), do: conn |> get(path) |> html_response(200) |> Floki.parse_document!()

  # Where the links inside `selector` point, in page order.
  defp links(html, selector), do: html |> Floki.find(selector <> " a") |> Floki.attribute("href")

  defp text(html, selector), do: html |> Floki.find(selector) |> Floki.text() |> String.trim()

  defp conn_for(conn, :visitor), do: conn
  defp conn_for(conn, :member), do: log_in_user(conn, user_fixture())
  defp conn_for(conn, :admin), do: log_in_user(conn, admin_fixture())

  describe "a visitor" do
    test "sees no page links on any page, and is offered to log in or register", %{conn: conn} do
      for path <- @visitor_pages do
        html = page(conn, path)

        assert links(html, "#main-nav") == [], path
        assert Floki.find(html, "#mobile-nav") == [], path
        assert Floki.find(html, "#user-menu") == [], path
        assert Enum.sort(links(html, "#guest-menu")) == ["/users/log_in", "/users/register"], path
      end
    end
  end

  describe "a member" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "sees links to chat, upload and search on every page, in the top bar and the collapsed menu",
         %{conn: conn} do
      for path <- @member_pages do
        html = page(conn, path)

        assert links(html, "#main-nav") == @member_links, path
        assert links(html, "#mobile-nav") == @member_links, path
      end
    end

    test "sees no link to the admin area on any page", %{conn: conn} do
      for path <- @member_pages do
        refute "/admin" in links(page(conn, path), "body"), path
      end
    end

    test "has a user menu on every page: the username, change password, log out",
         %{conn: conn, user: user} do
      for path <- @member_pages do
        html = page(conn, path)

        assert text(html, "#user-menu-username") == user.username, path
        assert links(html, "#user-menu") == ["/users/settings", "/users/log_out"], path
        assert Floki.find(html, "#guest-menu") == [], path
      end
    end
  end

  describe "an admin" do
    setup %{conn: conn} do
      %{conn: log_in_user(conn, admin_fixture())}
    end

    test "sees the member's links and then the admin area on every page, the admin page included",
         %{conn: conn} do
      for path <- @admin_pages do
        html = page(conn, path)

        assert links(html, "#main-nav") == @admin_links, path
        assert links(html, "#mobile-nav") == @admin_links, path
      end
    end
  end

  describe "every page" do
    test "names the product in the top bar, linking home", %{conn: conn} do
      for {kind, pages} <- [visitor: @visitor_pages, member: @member_pages, admin: @admin_pages],
          path <- pages do
        [brand] = conn |> conn_for(kind) |> page(path) |> Floki.find("#brand")

        assert brand |> Floki.text() |> String.trim() == "Cake", path
        assert Floki.attribute(brand, "href") == ["/"], path
      end
    end

    test "is titled with its own name and then the product's, and the home page with the product's alone",
         %{conn: conn} do
      for {kind, titles} <- @titles, {path, title} <- titles do
        assert conn |> conn_for(kind) |> page(path) |> text("title") == title, path
      end
    end

    test "carries no Phoenix branding", %{conn: conn} do
      for {kind, pages} <- [visitor: @visitor_pages, member: @member_pages, admin: @admin_pages],
          path <- pages do
        body = conn |> conn_for(kind) |> get(path) |> html_response(200)

        refute body =~ "Phoenix Framework", path
        refute body =~ "phoenixframework.org", path
        refute body =~ "/images/logo.svg", path
      end
    end
  end
end
