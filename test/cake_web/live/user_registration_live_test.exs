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

    test "requires a username and a password, and offers an optional email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      assert has_element?(lv, ~s|#registration_form input[name="user[username]"][required]|)
      assert has_element?(lv, ~s|#registration_form input[name="user[password]"][required]|)
      assert has_element?(lv, ~s|#registration_form input[name="user[email]"]|)
      refute has_element?(lv, ~s|#registration_form input[name="user[email]"][required]|)
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
    test "creates account and logs the user in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      username = unique_user_username()
      email = unique_user_email()

      form =
        form(lv, "#registration_form",
          user: valid_user_attributes(username: username, email: email)
        )

      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/"

      # Now do logged in requests. The home page sends a signed-in user on
      # to the chat (#375), whose menu names the user by username; the
      # email is no longer shown.
      assert conn |> get("/") |> redirected_to() == ~p"/chat"

      response = conn |> get(~p"/chat") |> html_response(200)
      assert response =~ username
      refute response =~ email
      assert response =~ "Change password"
      assert response =~ "Log out"

      # A user who gave an email is still sent the confirmation instructions.
      assert_email_sent(to: email)
    end

    test "creates an account with no email and logs the user in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      username = unique_user_username()
      password = valid_user_password()

      form =
        form(lv, "#registration_form", user: %{username: username, email: "", password: password})

      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/"
      assert conn |> get(~p"/chat") |> html_response(200) =~ username

      user = Accounts.get_user_by_username_and_password(username, password)
      assert is_nil(user.email)

      # No address, so no confirmation instructions.
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
        "user" => %{"username" => username, "password" => password, "role" => "admin"}
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
