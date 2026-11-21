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
  @member_pages ["/chat", "/documents", "/search", "/upload", "/users/settings"]
  @admin_pages ["/chat", "/documents", "/search", "/upload", "/users/settings", "/admin"]

  @member_links ["/chat", "/documents", "/upload", "/search"]
  @admin_links ["/chat", "/documents", "/upload", "/search", "/admin"]

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
      {"/documents", "Documents · Cake"},
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

  # What the entries inside `selector` say, linked or not, in page order.
  defp entries(html, selector) do
    html |> Floki.find(selector <> " li") |> Enum.map(&String.trim(Floki.text(&1)))
  end

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

    test "sees chat, documents, upload and search on every page, in the top bar and the collapsed menu, as links to every page but the one being shown",
         %{conn: conn} do
      for path <- @member_pages, nav <- ["#main-nav", "#mobile-nav"] do
        html = page(conn, path)

        assert entries(html, nav) == ["Chat", "Documents", "Upload", "Search"], path
        assert links(html, nav) == @member_links -- [path], path
      end
    end

    # A link to the page being shown would remount it: on the chat, that
    # throws the conversation away.
    test "sees the page being shown marked as current and not linked", %{conn: conn} do
      for {path, label} <- [
            {"/chat", "Chat"},
            {"/documents", "Documents"},
            {"/upload", "Upload"},
            {"/search", "Search"}
          ],
          nav <- ["#main-nav", "#mobile-nav"] do
        html = page(conn, path)

        assert text(html, ~s|#{nav} [aria-current="page"]|) == label, path
      end

      assert Floki.find(page(conn, "/users/settings"), ~s|header [aria-current="page"]|) == []
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
      for path <- @admin_pages, nav <- ["#main-nav", "#mobile-nav"] do
        html = page(conn, path)

        assert entries(html, nav) == ["Chat", "Documents", "Upload", "Search", "Admin"], path
        assert links(html, nav) == @admin_links -- [path], path
      end
    end

    test "sees the admin page marked as current and not linked while on it", %{conn: conn} do
      html = page(conn, "/admin")

      assert text(html, ~s|#main-nav [aria-current="page"]|) == "Admin"
      assert text(html, ~s|#mobile-nav [aria-current="page"]|) == "Admin"
    end
  end

  describe "every page" do
    test "names the product in the top bar, linking home for a visitor and to the chat for a user",
         %{conn: conn} do
      for {kind, pages, href} <- [
            {:visitor, @visitor_pages, "/"},
            {:member, @member_pages, "/chat"},
            {:admin, @admin_pages, "/chat"}
          ],
          path <- pages do
        [brand] = conn |> conn_for(kind) |> page(path) |> Floki.find("#brand")

        assert brand |> Floki.text() |> String.trim() == "Cake", path

        # On the chat itself the name is not a link: it would reload the chat.
        expected = if path == "/chat", do: [], else: [href]
        assert Floki.attribute(brand, "href") == expected, path
      end
    end

    # 4: the two pages reached with a token from an email.
    test "titles the pages reached with a token too", %{conn: conn} do
      # Confirmation instructions go only to a user not yet confirmed.
      user = unconfirmed_user_fixture()

      reset_token =
        extract_user_token(&Cake.Accounts.deliver_user_reset_password_instructions(user, &1))

      confirm_token =
        extract_user_token(&Cake.Accounts.deliver_user_confirmation_instructions(user, &1))

      assert conn |> page("/users/reset_password/#{reset_token}") |> text("title") ==
               "Reset password · Cake"

      assert conn |> page("/users/confirm/#{confirm_token}") |> text("title") ==
               "Confirm account · Cake"
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
        refute body =~ "favicon.ico", path
      end
    end

    # There is no Cake icon yet (README "Roadmap"). Until there is, the pages
    # declare an empty one, so a browser does not ask for /favicon.ico.
    test "declares an empty icon, and Phoenix's icon and logo are no longer served", %{conn: conn} do
      html = page(conn, "/")

      assert Floki.attribute(html, ~s|link[rel="icon"]|, "href") == ["data:,"]
      assert conn |> get("/favicon.ico") |> html_response(404)
      assert conn |> get("/images/logo.svg") |> html_response(404)
    end
  end
end
