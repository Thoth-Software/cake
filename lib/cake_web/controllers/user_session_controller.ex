defmodule CakeWeb.UserSessionController do
  use CakeWeb, :controller

  alias Cake.Accounts
  alias Cake.Accounts.User
  alias CakeWeb.UserAuth

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
        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      # In order to prevent user enumeration attacks, don't disclose whether the username is registered.
      nil ->
        refuse(conn, username, "Invalid username or password")
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
