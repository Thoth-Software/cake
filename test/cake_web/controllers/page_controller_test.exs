defmodule CakeWeb.PageControllerTest do
  @moduledoc """
  The home page (#375): a visitor is shown what Cake is and where to log
  in, and a signed-in user is sent on to the chat.
  """

  use CakeWeb.ConnCase, async: true

  import Cake.AccountsFixtures

  @not_authorized "You are not authorized to access this page."

  defp text(html, selector), do: html |> Floki.find(selector) |> Floki.text() |> String.trim()

  describe "GET /, signed out" do
    test "shows the product name, a sentence about it and a log-in button", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200) |> Floki.parse_document!()

      assert text(html, "#home-title") == "Cake"
      assert text(html, "#home-tagline") != ""
      assert Floki.attribute(html, "#home-log-in", "href") == [~p"/users/log_in"]
    end

    test "is no longer the Phoenix welcome page", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)

      refute body =~ "Peace of mind from prototype to production"
      refute body =~ "phoenixframework.org"
    end
  end

  describe "GET /, signed in" do
    test "sends a member to the chat", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get(~p"/")

      assert redirected_to(conn) == ~p"/chat"
    end

    test "sends an admin to the chat", %{conn: conn} do
      conn = conn |> log_in_user(admin_fixture()) |> get(~p"/")

      assert redirected_to(conn) == ~p"/chat"
    end

    # The admin area turns a member away to "/" with a flash. "/" now sends
    # them on again, and the flash has to arrive with them.
    test "carries a flash through to the chat page", %{conn: conn} do
      turned_away = conn |> log_in_user(user_fixture()) |> get(~p"/admin")
      assert redirected_to(turned_away) == ~p"/"

      sent_on = get(turned_away, ~p"/")
      assert redirected_to(sent_on) == ~p"/chat"

      html = sent_on |> get(~p"/chat") |> html_response(200) |> Floki.parse_document!()
      assert text(html, "#flash-error") =~ @not_authorized
    end
  end
end
