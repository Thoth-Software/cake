defmodule CakeWeb.UserSessionControllerTest do
  use CakeWeb.ConnCase, async: true

  import Cake.AccountsFixtures

  setup do
    %{user: user_fixture()}
  end

  describe "POST /users/log_in" do
    test "logs the user in", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log_in", %{
          "user" => %{"username" => user.username, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      # Now do logged in requests. The home page sends a signed-in user on
      # to the chat (#375), whose menu names the user by username; the
      # email is no longer shown.
      assert conn |> get(~p"/") |> redirected_to() == ~p"/chat"

      response = conn |> get(~p"/chat") |> html_response(200)
      assert response =~ user.username
      refute response =~ user.email
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log_out"
    end

    test "logs the user in whatever the letter case of the username", %{conn: conn} do
      username = "Mixed.Case-#{System.unique_integer([:positive])}"
      user_fixture(username: username)

      for typed <- [String.downcase(username), String.upcase(username)] do
        conn =
          post(conn, ~p"/users/log_in", %{
            "user" => %{"username" => typed, "password" => valid_user_password()}
          })

        assert get_session(conn, :user_token)
        assert redirected_to(conn) == ~p"/"

        # The menu shows the username as it was registered, not as it was typed.
        assert conn |> get(~p"/chat") |> html_response(200) =~ username
      end
    end

    test "logs in a user who has no email", %{conn: conn} do
      user = user_fixture(email: nil)

      conn =
        post(conn, ~p"/users/log_in", %{
          "user" => %{"username" => user.username, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
      assert conn |> get(~p"/chat") |> html_response(200) =~ user.username
    end

    test "logs the user in with remember me", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log_in", %{
          "user" => %{
            "username" => user.username,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_cake_web_user_remember_me"]
      assert redirected_to(conn) == ~p"/"
    end

    test "logs the user in with return to", %{conn: conn, user: user} do
      conn =
        conn
        |> init_test_session(user_return_to: "/foo/bar")
        |> post(~p"/users/log_in", %{
          "user" => %{
            "username" => user.username,
            "password" => valid_user_password()
          }
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "login following registration", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log_in", %{
          "_action" => "registered",
          "user" => %{
            "username" => user.username,
            "password" => valid_user_password()
          }
        })

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Account created successfully"
    end

    test "login following password update", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log_in", %{
          "_action" => "password_updated",
          "user" => %{
            "username" => user.username,
            "password" => valid_user_password()
          }
        })

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Password updated successfully"
    end

    test "redirects to login page with invalid credentials", %{conn: conn} do
      conn =
        post(conn, ~p"/users/log_in", %{
          "user" => %{"username" => "no.such-member", "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid username or password"
      assert redirected_to(conn) == ~p"/users/log_in"
    end

    # No user enumeration: nothing in the answer says which half was wrong.
    test "answers an unknown username and a wrong password alike", %{conn: conn, user: user} do
      refused = fn username, password ->
        conn =
          post(conn, ~p"/users/log_in", %{
            "user" => %{"username" => username, "password" => password}
          })

        refute get_session(conn, :user_token)
        {conn.status, redirected_to(conn), Phoenix.Flash.get(conn.assigns.flash, :error)}
      end

      unknown_username = refused.("no.such-member", valid_user_password())
      wrong_password = refused.(user.username, "not the password")

      assert unknown_username == {302, ~p"/users/log_in", "Invalid username or password"}
      assert wrong_password == unknown_username
    end

    test "does not take the user's email in place of the username", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log_in", %{
          "user" => %{"username" => user.email, "password" => valid_user_password()}
        })

      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid username or password"
      assert redirected_to(conn) == ~p"/users/log_in"
    end

    # A NUL byte must not reach the database, where it is an encoding error
    # (and so a 500): it is one more bad log-in.
    test "refuses a username with a NUL byte like any other bad log-in", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log_in", %{
          "user" => %{"username" => user.username <> "\0", "password" => valid_user_password()}
        })

      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid username or password"
      assert redirected_to(conn) == ~p"/users/log_in"
    end
  end

  describe "DELETE /users/log_out" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/users/log_out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log_out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end
end
