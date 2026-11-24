defmodule CakeWeb.UserConfirmationLiveTest do
  use CakeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Cake.AccountsFixtures

  alias Cake.Accounts
  alias Cake.Repo

  setup do
    %{user: unconfirmed_user_fixture()}
  end

  describe "Confirm user" do
    test "renders confirmation page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/confirm/some-token")
      assert html =~ "Confirm account"
    end

    test "confirms the given token once", %{conn: conn, user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/users/confirm/#{token}")

      result =
        lv
        |> form("#confirmation_form")
        |> render_submit()
        |> follow_redirect(conn, "/")

      assert {:ok, conn} = result

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "User confirmed successfully"

      assert Accounts.get_user!(user.id).confirmed_at
      refute get_session(conn, :user_token)
      assert Repo.all(Accounts.UserToken) == []

      # when not logged in
      {:ok, not_logged_in_lv, _html} = live(conn, ~p"/users/confirm/#{token}")

      not_logged_in_result =
        not_logged_in_lv
        |> form("#confirmation_form")
        |> render_submit()
        |> follow_redirect(conn, "/")

      assert {:ok, not_logged_in_conn} = not_logged_in_result

      assert Phoenix.Flash.get(not_logged_in_conn.assigns.flash, :error) =~
               "User confirmation link is invalid or it has expired"

      # when logged in
      logged_in_conn = log_in_user(build_conn(), user)

      {:ok, logged_in_lv, _html} = live(logged_in_conn, ~p"/users/confirm/#{token}")

      logged_in_result =
        logged_in_lv
        |> form("#confirmation_form")
        |> render_submit()
        |> follow_redirect(logged_in_conn, "/")

      assert {:ok, confirmed_conn} = logged_in_result
      refute Phoenix.Flash.get(confirmed_conn.assigns.flash, :error)
    end

    test "does not confirm email with invalid token", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/confirm/invalid-token")

      {:ok, conn} =
        lv
        |> form("#confirmation_form")
        |> render_submit()
        |> follow_redirect(conn, ~p"/")

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "User confirmation link is invalid or it has expired"

      refute Accounts.get_user!(user.id).confirmed_at
    end

    # #427. Deleted while the page is open, behind the context's back: the
    # link is no longer good, and the page answers as it answers any link
    # it does not accept.
    test "answers a link whose user was deleted while the page was open as one it does not accept",
         %{conn: conn, user: user} do
      token = extract_user_token(&Accounts.deliver_user_confirmation_instructions(user, &1))
      {:ok, lv, _html} = live(conn, ~p"/users/confirm/#{token}")
      Repo.delete!(user)

      lv |> form("#confirmation_form") |> render_submit()

      assert assert_redirect(lv, ~p"/") == %{
               "error" => "User confirmation link is invalid or it has expired."
             }
    end
  end
end
