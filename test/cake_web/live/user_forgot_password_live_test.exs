defmodule CakeWeb.UserForgotPasswordLiveTest do
  use CakeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import Cake.AccountsFixtures

  alias Cake.Accounts
  alias Cake.Repo

  describe "Forgot password page" do
    test "renders email page", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/reset_password")

      assert html =~ "Forgot your password?"
      assert has_element?(lv, ~s|a[href="#{~p"/users/register"}"]|, "Register")
      assert has_element?(lv, ~s|a[href="#{~p"/users/log_in"}"]|, "Log in")
    end

    # The page cannot know who is reading it, so it says this to everyone.
    test "tells a user without an email to ask an administrator", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset_password")

      assert has_element?(lv, "#reset-password-no-email", "ask an administrator")
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/reset_password")
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _conn} = result
    end
  end

  describe "Reset link" do
    setup do
      %{user: user_fixture()}
    end

    test "sends a new reset password token", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset_password")

      {:ok, conn} =
        lv
        |> form("#reset_password_form", user: %{"email" => user.email})
        |> render_submit()
        |> follow_redirect(conn, "/")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "If your email is in our system"

      assert Repo.get_by!(Accounts.UserToken, user_id: user.id).context ==
               "reset_password"
    end

    test "does not send reset password token if email is invalid", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset_password")

      {:ok, conn} =
        lv
        |> form("#reset_password_form", user: %{"email" => "unknown@example.com"})
        |> render_submit()
        |> follow_redirect(conn, "/")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "If your email is in our system"
      assert Repo.all(Accounts.UserToken) == []
    end
  end

  # A user with no email cannot reset a password this way: there is no
  # address to send the link to. The request is answered as every other is.
  describe "Reset link, for a user with no email" do
    setup do
      %{user: user_fixture(email: nil)}
    end

    test "sends nothing for the username, or nothing, typed in place of an email", %{
      conn: conn,
      user: user
    } do
      for typed <- [user.username, ""] do
        {:ok, lv, _html} = live(conn, ~p"/users/reset_password")

        {:ok, conn} =
          lv
          |> element("#reset_password_form")
          |> render_submit(user: %{"email" => typed})
          |> follow_redirect(conn, "/")

        assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "If your email is in our system"
      end

      assert Repo.all(Accounts.UserToken) == []
      assert_no_email_sent()
    end
  end

  # What the visitor is told and where they are sent must not say whether
  # the email belongs to anyone.
  describe "Reset link, the answer" do
    test "is the same for a matching email, an unknown one and an email-less user", %{conn: conn} do
      with_email = user_fixture()
      without_email = user_fixture(email: nil)

      answers =
        for typed <- [with_email.email, "unknown@example.com", without_email.username] do
          {:ok, lv, _html} = live(conn, ~p"/users/reset_password")

          # The redirect carries the flash signed with a timestamp, so the
          # comparison is of what the visitor reads after following it.
          {:ok, conn} =
            lv
            |> element("#reset_password_form")
            |> render_submit(user: %{"email" => typed})
            |> follow_redirect(conn, ~p"/")

          conn.assigns.flash
        end

      assert [answer, answer, answer] = answers
      assert %{"info" => "If your email is in our system" <> _} = answer
    end
  end
end
