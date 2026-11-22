defmodule CakeWeb.UserAuthTest.TwoHooksLive do
  @moduledoc false
  # A LiveView that stacks two of UserAuth's hooks, as the `on_mount/4`
  # @doc shows a LiveView declaring its own.
  use CakeWeb, :live_view

  on_mount {CakeWeb.UserAuth, :mount_current_user}
  on_mount {CakeWeb.UserAuth, :ensure_authenticated}

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns), do: ~H"<p id=\"who\">{@current_user.username}</p>"
end

defmodule CakeWeb.UserAuthTest do
  use CakeWeb.ConnCase, async: true

  import Cake.AccountsFixtures

  import Phoenix.LiveViewTest,
    only: [
      live: 2,
      live_isolated: 3,
      element: 2,
      render: 1,
      assert_redirect: 1,
      assert_redirect: 2
    ]

  alias Cake.Accounts
  alias CakeWeb.UserAuth
  alias Phoenix.LiveView

  @remember_me_cookie "_cake_web_user_remember_me"

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, CakeWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})

    %{user: user_fixture(), conn: conn}
  end

  describe "log_in_user/3" do
    test "stores the user token in the session", %{conn: conn, user: user} do
      conn = UserAuth.log_in_user(conn, user)
      assert token = get_session(conn, :user_token)
      assert get_session(conn, :live_socket_id) == "users_sessions:#{Base.url_encode64(token)}"
      assert redirected_to(conn) == ~p"/"
      assert Accounts.get_user_by_session_token(token)
    end

    test "clears everything previously stored in the session", %{conn: conn, user: user} do
      conn = conn |> put_session(:to_be_removed, "value") |> UserAuth.log_in_user(user)
      refute get_session(conn, :to_be_removed)
    end

    test "redirects to the configured path", %{conn: conn, user: user} do
      conn = conn |> put_session(:user_return_to, "/hello") |> UserAuth.log_in_user(user)
      assert redirected_to(conn) == "/hello"
    end

    test "writes a cookie if remember_me is configured", %{conn: conn, user: user} do
      conn = conn |> fetch_cookies() |> UserAuth.log_in_user(user, %{"remember_me" => "true"})
      assert get_session(conn, :user_token) == conn.cookies[@remember_me_cookie]

      assert %{value: signed_token, max_age: max_age} = conn.resp_cookies[@remember_me_cookie]
      assert signed_token != get_session(conn, :user_token)
      assert max_age == 5_184_000
    end
  end

  describe "logout_user/1" do
    test "erases session and cookies", %{conn: conn, user: user} do
      user_token = Accounts.generate_user_session_token(user)

      conn =
        conn
        |> put_session(:user_token, user_token)
        |> put_req_cookie(@remember_me_cookie, user_token)
        |> fetch_cookies()
        |> UserAuth.log_out_user()

      refute get_session(conn, :user_token)
      refute conn.cookies[@remember_me_cookie]
      assert %{max_age: 0} = conn.resp_cookies[@remember_me_cookie]
      assert redirected_to(conn) == ~p"/"
      refute Accounts.get_user_by_session_token(user_token)
    end

    test "broadcasts to the given live_socket_id", %{conn: conn} do
      live_socket_id = "users_sessions:abcdef-token"
      CakeWeb.Endpoint.subscribe(live_socket_id)

      conn
      |> put_session(:live_socket_id, live_socket_id)
      |> UserAuth.log_out_user()

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^live_socket_id}
    end

    test "works even if user is already logged out", %{conn: conn} do
      conn = conn |> fetch_cookies() |> UserAuth.log_out_user()
      refute get_session(conn, :user_token)
      assert %{max_age: 0} = conn.resp_cookies[@remember_me_cookie]
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "fetch_current_user/2" do
    test "authenticates user from session", %{conn: conn, user: user} do
      user_token = Accounts.generate_user_session_token(user)
      conn = conn |> put_session(:user_token, user_token) |> UserAuth.fetch_current_user([])
      assert conn.assigns.current_user.id == user.id
    end

    test "authenticates user from cookies", %{conn: conn, user: user} do
      logged_in_conn =
        conn |> fetch_cookies() |> UserAuth.log_in_user(user, %{"remember_me" => "true"})

      user_token = logged_in_conn.cookies[@remember_me_cookie]
      %{value: signed_token} = logged_in_conn.resp_cookies[@remember_me_cookie]

      conn =
        conn
        |> put_req_cookie(@remember_me_cookie, signed_token)
        |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user.id == user.id
      assert get_session(conn, :user_token) == user_token

      assert get_session(conn, :live_socket_id) ==
               "users_sessions:#{Base.url_encode64(user_token)}"
    end

    test "does not authenticate if data is missing", %{conn: conn, user: user} do
      _ = Accounts.generate_user_session_token(user)
      conn = UserAuth.fetch_current_user(conn, [])
      refute get_session(conn, :user_token)
      refute conn.assigns.current_user
    end
  end

  # Every hook subscribes a connected page to its user's topic, so that
  # end_live_sessions/1 can send the page away (#376).
  describe "a connected page whose user's sessions are ended" do
    test "mounts and is sent away once, with two of UserAuth's hooks stacked", %{user: user} do
      token = Accounts.generate_user_session_token(user)

      {:ok, lv, _html} =
        live_isolated(build_conn(), CakeWeb.UserAuthTest.TwoHooksLive,
          session: %{"user_token" => token}
        )

      assert lv |> element("#who") |> render() =~ user.username

      :ok = UserAuth.end_live_sessions(user)

      assert_redirect(lv, ~p"/users/log_in")
    end

    # On a page anyone may open the user is not required to log in, so the
    # message says what happened, not that the page needs a log-in.
    test "is told that its session has ended, on a page that needs no log-in", %{
      conn: conn,
      user: user
    } do
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/users/confirm")

      :ok = UserAuth.end_live_sessions(user)

      assert {_path, flash} = assert_redirect(lv)
      assert flash["error"] == "Your session has ended. Log in again to go on."
    end
  end

  describe "on_mount :mount_current_user" do
    test "assigns current_user based on a valid user_token", %{conn: conn, user: user} do
      user_token = Accounts.generate_user_session_token(user)
      session = conn |> put_session(:user_token, user_token) |> get_session()

      {:cont, updated_socket} =
        UserAuth.on_mount(:mount_current_user, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_user.id == user.id
    end

    test "assigns nil to current_user assign if there isn't a valid user_token", %{conn: conn} do
      user_token = "invalid_token"
      session = conn |> put_session(:user_token, user_token) |> get_session()

      {:cont, updated_socket} =
        UserAuth.on_mount(:mount_current_user, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_user == nil
    end

    test "assigns nil to current_user assign if there isn't a user_token", %{conn: conn} do
      session = get_session(conn)

      {:cont, updated_socket} =
        UserAuth.on_mount(:mount_current_user, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_user == nil
    end
  end

  describe "on_mount :ensure_authenticated" do
    test "authenticates current_user based on a valid user_token", %{conn: conn, user: user} do
      user_token = Accounts.generate_user_session_token(user)
      session = conn |> put_session(:user_token, user_token) |> get_session()

      {:cont, updated_socket} =
        UserAuth.on_mount(:ensure_authenticated, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_user.id == user.id
    end

    test "redirects to login page if there isn't a valid user_token", %{conn: conn} do
      user_token = "invalid_token"
      session = conn |> put_session(:user_token, user_token) |> get_session()

      socket = %LiveView.Socket{
        endpoint: CakeWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      {:halt, updated_socket} = UserAuth.on_mount(:ensure_authenticated, %{}, session, socket)
      assert updated_socket.assigns.current_user == nil
    end

    test "redirects to login page if there isn't a user_token", %{conn: conn} do
      session = get_session(conn)

      socket = %LiveView.Socket{
        endpoint: CakeWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      {:halt, updated_socket} = UserAuth.on_mount(:ensure_authenticated, %{}, session, socket)
      assert updated_socket.assigns.current_user == nil
    end
  end

  describe "on_mount :redirect_if_user_is_authenticated" do
    test "redirects if there is an authenticated  user ", %{conn: conn, user: user} do
      user_token = Accounts.generate_user_session_token(user)
      session = conn |> put_session(:user_token, user_token) |> get_session()

      assert {:halt, _updated_socket} =
               UserAuth.on_mount(
                 :redirect_if_user_is_authenticated,
                 %{},
                 session,
                 %LiveView.Socket{}
               )
    end

    test "doesn't redirect if there is no authenticated user", %{conn: conn} do
      session = get_session(conn)

      assert {:cont, _updated_socket} =
               UserAuth.on_mount(
                 :redirect_if_user_is_authenticated,
                 %{},
                 session,
                 %LiveView.Socket{}
               )
    end
  end

  describe "redirect_if_user_is_authenticated/2" do
    test "redirects if user is authenticated", %{conn: conn, user: user} do
      conn = conn |> assign(:current_user, user) |> UserAuth.redirect_if_user_is_authenticated([])
      assert conn.halted
      assert redirected_to(conn) == ~p"/"
    end

    test "does not redirect if user is not authenticated", %{conn: conn} do
      conn = UserAuth.redirect_if_user_is_authenticated(conn, [])
      refute conn.halted
      refute conn.status
    end
  end

  describe "require_authenticated_user/2" do
    test "redirects if user is not authenticated", %{conn: conn} do
      conn = conn |> fetch_flash() |> UserAuth.require_authenticated_user([])
      assert conn.halted

      assert redirected_to(conn) == ~p"/users/log_in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must log in to access this page."
    end

    test "stores the path to redirect to on GET", %{conn: conn} do
      halted_conn =
        %{conn | path_info: ["foo"], query_string: ""}
        |> fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert halted_conn.halted
      assert get_session(halted_conn, :user_return_to) == "/foo"

      halted_conn_with_query =
        %{conn | path_info: ["foo"], query_string: "bar=baz"}
        |> fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert halted_conn_with_query.halted
      assert get_session(halted_conn_with_query, :user_return_to) == "/foo?bar=baz"

      halted_conn_post =
        %{conn | path_info: ["foo"], query_string: "bar", method: "POST"}
        |> fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert halted_conn_post.halted
      refute get_session(halted_conn_post, :user_return_to)
    end

    test "does not redirect if user is authenticated", %{conn: conn, user: user} do
      conn = conn |> assign(:current_user, user) |> UserAuth.require_authenticated_user([])
      refute conn.halted
      refute conn.status
    end
  end

  # A halted LiveView socket, as the hooks leave it when they turn a visitor
  # away: one that can carry a flash and a redirect.
  defp live_socket do
    %LiveView.Socket{endpoint: CakeWeb.Endpoint, assigns: %{__changed__: %{}, flash: %{}}}
  end

  defp session_for(conn, user) do
    conn |> put_session(:user_token, Accounts.generate_user_session_token(user)) |> get_session()
  end

  describe "on_mount :ensure_admin" do
    test "lets an admin through, with current_user assigned", %{conn: conn} do
      admin = admin_fixture()

      {:cont, updated_socket} =
        UserAuth.on_mount(:ensure_admin, %{}, session_for(conn, admin), live_socket())

      assert updated_socket.assigns.current_user.id == admin.id
    end

    test "sends a member to the home page with a not-authorized flash", %{conn: conn, user: user} do
      {:halt, updated_socket} =
        UserAuth.on_mount(:ensure_admin, %{}, session_for(conn, user), live_socket())

      assert {:redirect, %{to: "/"}} = updated_socket.redirected

      assert Phoenix.Flash.get(updated_socket.assigns.flash, :error) ==
               "You are not authorized to access this page."
    end

    # The hook is safe on its own: it does not rely on `:ensure_authenticated`
    # having run before it.
    test "sends a visitor with no user_token to the log-in page", %{conn: conn} do
      {:halt, updated_socket} =
        UserAuth.on_mount(:ensure_admin, %{}, get_session(conn), live_socket())

      assert updated_socket.assigns.current_user == nil
      assert {:redirect, %{to: "/users/log_in"}} = updated_socket.redirected

      assert Phoenix.Flash.get(updated_socket.assigns.flash, :error) ==
               "You must log in to access this page."
    end

    test "sends a visitor with an invalid user_token to the log-in page", %{conn: conn} do
      session = conn |> put_session(:user_token, "invalid_token") |> get_session()

      {:halt, updated_socket} = UserAuth.on_mount(:ensure_admin, %{}, session, live_socket())

      assert updated_socket.assigns.current_user == nil
      assert {:redirect, %{to: "/users/log_in"}} = updated_socket.redirected
    end

    test "reads the role when it mounts: a demoted admin is turned away", %{conn: conn} do
      admin = admin_fixture()
      admin_fixture()
      session = session_for(conn, admin)

      assert {:cont, _socket} = UserAuth.on_mount(:ensure_admin, %{}, session, live_socket())

      {:ok, _demoted} = Accounts.update_user_role(admin, :member)

      assert {:halt, updated_socket} =
               UserAuth.on_mount(:ensure_admin, %{}, session, live_socket())

      assert {:redirect, %{to: "/"}} = updated_socket.redirected
    end
  end

  describe "require_admin/2" do
    test "does not redirect an admin", %{conn: conn} do
      conn = conn |> assign(:current_user, admin_fixture()) |> UserAuth.require_admin([])

      refute conn.halted
      refute conn.status
    end

    test "sends a member to the home page with a not-authorized flash", %{conn: conn, user: user} do
      conn = conn |> fetch_flash() |> assign(:current_user, user) |> UserAuth.require_admin([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You are not authorized to access this page."
    end

    # The plug is safe on its own: it does not rely on
    # `require_authenticated_user/2` having run before it.
    test "sends a visitor who is not logged in to the log-in page", %{conn: conn} do
      conn = conn |> fetch_flash() |> UserAuth.require_admin([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/users/log_in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must log in to access this page."
    end

    test "stores the path a visitor who is not logged in asked for, on GET", %{conn: conn} do
      halted_conn =
        %{conn | path_info: ["admin"], query_string: ""}
        |> fetch_flash()
        |> UserAuth.require_admin([])

      assert halted_conn.halted
      assert get_session(halted_conn, :user_return_to) == "/admin"
    end

    # A member is not coming back to this page after logging in again.
    test "does not store the path a member asked for", %{conn: conn, user: user} do
      halted_conn =
        %{conn | path_info: ["admin"], query_string: ""}
        |> fetch_flash()
        |> assign(:current_user, user)
        |> UserAuth.require_admin([])

      assert halted_conn.halted
      refute get_session(halted_conn, :user_return_to)
    end
  end
end
