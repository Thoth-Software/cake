defmodule CakeWeb.AdminLiveTest do
  @moduledoc """
  The `/admin` scope and its landing page (#373): who may open it.

  The landing page is minimal on purpose. It is here so the guard has a real
  route to protect; the admin panel (#376) fills it.
  """

  use CakeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Cake.AccountsFixtures

  alias Cake.Accounts

  @not_authorized "You are not authorized to access this page."
  @must_log_in "You must log in to access this page."

  # The text content of the one element `selector` matches in the LiveView,
  # without the whitespace the template puts around it. `element/2` raises
  # unless exactly one element matches.
  defp text_of(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.text()
    |> String.trim()
  end

  describe "GET /admin, as a LiveView" do
    test "mounts for an admin, under the heading Admin", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in_user(admin_fixture()) |> live(~p"/admin")

      assert text_of(lv, "h1") == "Admin"
    end

    test "sends a member to the home page with a not-authorized flash", %{conn: conn} do
      assert {:error, redirect} = conn |> log_in_user(user_fixture()) |> live(~p"/admin")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/"
      assert %{"error" => @not_authorized} = flash
    end

    test "sends a visitor who is not logged in to the log-in page", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/admin")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log_in"
      assert %{"error" => @must_log_in} = flash
    end

    test "turns a demoted admin away on their next navigation", %{conn: conn} do
      admin = admin_fixture()
      admin_fixture()
      conn = log_in_user(conn, admin)

      assert {:ok, _lv, _html} = live(conn, ~p"/admin")

      {:ok, _demoted} = Accounts.update_user_role(admin, :member)

      assert {:error, {:redirect, %{to: path, flash: flash}}} = live(conn, ~p"/admin")
      assert path == ~p"/"
      assert %{"error" => @not_authorized} = flash
    end

    test "lets a promoted member in on their next navigation", %{conn: conn} do
      member = user_fixture()
      conn = log_in_user(conn, member)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin")

      {:ok, _promoted} = Accounts.update_user_role(member, :admin)

      assert {:ok, _lv, _html} = live(conn, ~p"/admin")
    end

    test "sends a deleted user to the log-in page", %{conn: conn} do
      admin = admin_fixture()
      admin_fixture()
      conn = log_in_user(conn, admin)

      assert {:ok, _lv, _html} = live(conn, ~p"/admin")

      {:ok, _deleted} = Accounts.delete_user(admin)

      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin")
      assert path == ~p"/users/log_in"
    end
  end

  # The same route over plain HTTP, where the plug answers before any
  # LiveView is rendered.
  describe "GET /admin, as a request" do
    test "answers an admin with the page", %{conn: conn} do
      conn = conn |> log_in_user(admin_fixture()) |> get(~p"/admin")

      assert html_response(conn, 200)
    end

    test "redirects a member to the home page with a not-authorized flash", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get(~p"/admin")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == @not_authorized
    end

    test "redirects a visitor who is not logged in to the log-in page, and remembers where they were going",
         %{conn: conn} do
      conn = get(conn, ~p"/admin")

      assert redirected_to(conn) == ~p"/users/log_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == @must_log_in
      assert get_session(conn, :user_return_to) == "/admin"
    end
  end
end
