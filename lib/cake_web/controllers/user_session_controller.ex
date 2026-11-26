defmodule CakeWeb.UserSessionController do
  @moduledoc """
  Logs users in and out; it renders no page. `create/2` takes the POST of
  the log-in form (`CakeWeb.UserLoginLive`) and looks the user up with
  `Cake.Accounts.get_user_by_username_and_password/2`. A wrong username and
  a wrong password get the same answer. A user whose email is unconfirmed
  is refused too and told why, an answer only a right password gets. Both
  refusals redirect to the log-in page; otherwise
  `CakeWeb.UserAuth.log_in_user/3` starts the session.

  The settings page posts to the same action with
  `_action=password_updated` after a password change, which has deleted the
  user's sessions: it logs them in again, under the same checks, and
  returns them to `/users/settings`. `delete/2` (`DELETE /users/log_out`)
  logs out and redirects to `/`, logged in or not.
  """

  use CakeWeb, :controller

  alias Cake.Accounts
  alias Cake.Accounts.User
  alias CakeWeb.UserAuth

  @invalid "Invalid username or password"

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"_action" => "password_updated"} = params) do
    conn
    |> put_session(:user_return_to, ~p"/users/settings")
    |> create(params, "Password updated successfully!")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  defp create(conn, %{"user" => user_params}, info) do
    %{"username" => username, "password" => password} = user_params

    case Accounts.get_user_by_username_and_password(username, password) do
      # Log-in waits on the email being confirmed. Saying so discloses
      # nothing: only someone with the right password gets this answer.
      %User{confirmed_at: nil} ->
        refuse(
          conn,
          username,
          "You must confirm your email before you can log in. Follow the link in the confirmation instructions we sent you."
        )

      %User{} = user ->
        case conn |> put_flash(:info, info) |> UserAuth.log_in_user(user, user_params) do
          {:ok, logged_in} -> logged_in
          # Deleted since the password was checked. Whoever tries a moment
          # later is told the username or the password is wrong, so this
          # log-in is told the same.
          {:error, :gone} -> refuse(conn, username, @invalid)
        end

      # In order to prevent user enumeration attacks, don't disclose whether the username is registered.
      nil ->
        refuse(conn, username, @invalid)
    end
  end

  defp refuse(conn, username, message) do
    conn
    |> put_flash(:error, message)
    |> put_flash(:username, String.slice(username, 0, 32))
    |> redirect(to: ~p"/users/log_in")
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
