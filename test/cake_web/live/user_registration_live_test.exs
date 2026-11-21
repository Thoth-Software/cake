defmodule CakeWeb.UserRegistrationLiveTest do
  use CakeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import Cake.AccountsFixtures

  alias Cake.Accounts

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Register"
      assert html =~ "Log in"
    end

    test "requires a username, an email and a password", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      assert has_element?(lv, ~s|#registration_form input[name="user[username]"][required]|)
      assert has_element?(lv, ~s|#registration_form input[name="user[password]"][required]|)
      assert has_element?(lv, ~s|#registration_form input[name="user[email]"][required]|)
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, "/")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(
          user: %{"username" => "no spaces!", "email" => "with spaces", "password" => "too short"}
        )

      assert result =~ "Register"
      assert result =~ "can only contain letters a-z, digits, underscores, dots and hyphens"
      assert result =~ "must have the @ sign and no spaces"
      assert result =~ "should be at least 12 character"
    end

    test "renders an error for a username that is too short", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"username" => "ab"})

      assert result =~ "should be at least 3 character"
    end
  end

  describe "register user" do
    # Log-in waits on the email being confirmed, so registering no longer
    # logs the user in: it sends the instructions and says to follow them.
    test "creates the account, sends confirmation instructions, and does not log the user in",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      username = unique_user_username()
      email = unique_user_email()
      password = valid_user_password()

      {:ok, conn} =
        lv
        |> form("#registration_form",
          user: %{username: username, email: email, password: password}
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log_in")

      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "confirm your email"
      assert_email_sent(to: email)

      user = Accounts.get_user_by_username_and_password(username, password)
      assert user.email == email
      assert is_nil(user.confirmed_at)
      assert Cake.Repo.get_by(Accounts.UserToken, user_id: user.id, context: "confirm")
    end

    test "refuses a registration with no email, and sends nothing", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      username = unique_user_username()
      password = valid_user_password()

      result =
        lv
        |> form("#registration_form", user: %{username: username, email: "", password: password})
        |> render_submit()

      assert result =~ "can&#39;t be blank"
      refute Accounts.get_user_by_username_and_password(username, password)
      assert_no_email_sent()
    end

    # The form has no role field; a hand-made request that adds one gets a member.
    test "creates a member even when the request carries a role", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      username = unique_user_username()
      password = valid_user_password()

      lv
      |> element("#registration_form")
      |> render_submit(%{
        "user" => %{
          "username" => username,
          "email" => unique_user_email(),
          "password" => password,
          "role" => "admin"
        }
      })

      user = Accounts.get_user_by_username_and_password(username, password)
      assert user.role == :member
    end

    test "renders errors for a duplicated username, whatever its letter case", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      username = "Taken.Name-#{System.unique_integer([:positive])}"
      user_fixture(username: username)

      result =
        lv
        |> form("#registration_form",
          user: %{"username" => String.upcase(username), "password" => valid_user_password()}
        )
        |> render_submit()

      assert result =~ "has already been taken"
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user = user_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form",
          user: %{"email" => user.email, "password" => "valid_password"}
        )
        |> render_submit()

      assert result =~ "has already been taken"
    end
  end

  describe "the form-level error notice" do
    test "is absent while typing, present after a refused submit, and gone once the form is valid",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      refute has_element?(lv, "#registration-errors")

      invalid = %{"username" => "ab", "password" => "short"}

      lv |> element("#registration_form") |> render_change(user: invalid)
      refute has_element?(lv, "#registration-errors")

      lv |> form("#registration_form", user: invalid) |> render_submit()
      assert has_element?(lv, "#registration-errors.alert-error")

      lv
      |> element("#registration_form")
      |> render_change(
        user: %{
          "username" => unique_user_username(),
          "email" => unique_user_email(),
          "password" => valid_user_password()
        }
      )

      refute has_element?(lv, "#registration-errors")
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element(~s|main a:fl-contains("Log in")|)
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log_in")

      assert login_html =~ "Log in"
    end
  end
end
