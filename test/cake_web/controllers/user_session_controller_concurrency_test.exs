defmodule CakeWeb.UserSessionControllerConcurrencyTest do
  @moduledoc """
  Logging in while the user is deleted (#427).

  `CakeWeb.UserSessionController` checks the password, then stores a
  session for the user (`CakeWeb.UserAuth.log_in_user/3`). A deletion can
  commit in between: the check found the user, and the session would refer
  to one who is gone. The log-in is then refused as a wrong username or
  password, as it is for anyone who tries a moment later. Nothing in the
  answer says that the username existed (README, "The Account Pages").

  The interleaving is fixed as `Cake.AccountsConcurrencyPropertyTest` fixes
  its own, with `Cake.ConcurrencyHelpers`: the deletion is held uncommitted
  until the log-in waits on it, then let commit. Both run outside the SQL
  sandbox and commit, so this module is `async: false` and deletes the user
  it made, first any a killed run left behind.
  """

  use ExUnit.Case, async: false
  use CakeWeb, :verified_routes

  import Cake.ConcurrencyHelpers
  import Ecto.Query
  import Phoenix.ConnTest
  import Plug.Conn

  alias Cake.Accounts
  alias Cake.Accounts.User
  alias Cake.Accounts.UserToken
  alias Cake.Repo

  @endpoint CakeWeb.Endpoint

  @username "login-racer"
  @password "hello world!"

  defp delete_racer do
    unboxed(fn -> Repo.delete_all(from u in User, where: u.username == @username) end)
  end

  setup do
    delete_racer()
    on_exit(&delete_racer/0)
  end

  # A member who can log in: `create_user/1` confirms from the start.
  defp create_racer do
    unboxed(fn ->
      {:ok, user} =
        Accounts.create_user(%{
          username: @username,
          email: "#{@username}@race.example",
          password: @password,
          role: :member
        })

      user
    end)
  end

  # The log-in form's POST, from a browser of its own, and what it answers:
  # the status, where it sends the browser, the flash, and the session
  # stored, if any.
  defp log_in(password) do
    conn =
      post(build_conn(), ~p"/users/log_in", %{
        "user" => %{"username" => @username, "password" => password}
      })

    {conn.status, redirected_to(conn), conn.assigns.flash, get_session(conn, :user_token)}
  end

  test "a log-in that waits on its user's deletion is refused as a wrong username or password, and stores no session" do
    user = create_racer()

    deletion = change_and_hold(fn -> Accounts.delete_user(user) end, self())
    assert_receive :change_uncommitted

    logging_in = Task.async(fn -> unboxed(fn -> log_in(@password) end) end)
    assert await_blocked_or_done(logging_in) == :blocked

    send(deletion.pid, :commit)
    assert {:ok, %User{}} = Task.await(deletion, 15_000)

    # What anyone is answered with a wrong password, now that the user is
    # gone, or an unknown username: the two are answered alike.
    refused = unboxed(fn -> log_in("not the password") end)

    assert refused ==
             {302, ~p"/users/log_in",
              %{"error" => "Invalid username or password", "username" => @username}, nil}

    assert Task.await(logging_in, 15_000) == refused
    refute unboxed(fn -> Repo.exists?(from t in UserToken, where: t.user_id == ^user.id) end)
  end
end
