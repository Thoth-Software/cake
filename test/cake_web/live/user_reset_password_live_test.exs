defmodule CakeWeb.UserResetPasswordLiveTest do
  use CakeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Cake.AccountsFixtures

  alias Cake.Accounts

  setup do
    user = user_fixture()

    token =
      extract_user_token(fn url ->
        Accounts.deliver_user_reset_password_instructions(user, url)
      end)

    %{token: token, user: user}
  end

  describe "Reset password page" do
    test "renders reset password with valid token", %{conn: conn, token: token} do
      {:ok, _lv, html} = live(conn, ~p"/users/reset_password/#{token}")

      assert html =~ "Reset password"
    end

    test "does not render reset password with invalid token", %{conn: conn} do
      {:error, {:redirect, to}} = live(conn, ~p"/users/reset_password/invalid")

      assert to == %{
               flash: %{"error" => "Reset password link is invalid or it has expired."},
               to: ~p"/"
             }
    end

    test "renders errors for invalid data", %{conn: conn, token: token} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset_password/#{token}")

      result =
        lv
        |> element("#reset_password_form")
        |> render_change(
          user: %{"password" => "secret12", "password_confirmation" => "secret123456"}
        )

      assert result =~ "should be at least 12 character"
      assert result =~ "does not match password"
    end
  end

  describe "Reset Password" do
    test "resets password once", %{conn: conn, token: token, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset_password/#{token}")

      {:ok, conn} =
        lv
        |> form("#reset_password_form",
          user: %{
            "password" => "new valid password",
            "password_confirmation" => "new valid password"
          }
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log_in")

      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Password reset successfully"
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "does not reset password on invalid data", %{conn: conn, token: token} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset_password/#{token}")

      result =
        lv
        |> form("#reset_password_form",
          user: %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        )
        |> render_submit()

      assert result =~ "Reset password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end
  end

  # The notice is an alert, which a screen reader speaks at once: it belongs
  # to a refused submit, not to a password that is still being typed.
  describe "the form-level error notice" do
    test "is absent while typing and present after a refused submit", %{conn: conn, token: token} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset_password/#{token}")
      refute has_element?(lv, "#reset-password-errors")

      invalid = %{"password" => "short", "password_confirmation" => "other"}

      lv |> element("#reset_password_form") |> render_change(user: invalid)
      refute has_element?(lv, "#reset-password-errors")

      lv |> form("#reset_password_form", user: invalid) |> render_submit()
      assert has_element?(lv, "#reset-password-errors.alert-error")
    end
  end

  describe "Reset password navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn, token: token} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset_password/#{token}")

      {:ok, conn} =
        lv
        |> element(~s|main a:fl-contains("Log in")|)
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log_in")

      assert conn.resp_body =~ "Log in"
    end

    test "redirects to registration page when the Register button is clicked", %{
      conn: conn,
      token: token
    } do
      {:ok, lv, _html} = live(conn, ~p"/users/reset_password/#{token}")

      {:ok, conn} =
        lv
        |> element(~s|main a:fl-contains("Register")|)
        |> render_click()
        |> follow_redirect(conn, ~p"/users/register")

      assert conn.resp_body =~ "Register"
    end
  end
end
