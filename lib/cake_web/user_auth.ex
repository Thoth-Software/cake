defmodule CakeWeb.UserAuth do
  @moduledoc """
  Authentication helpers for the web layer: logging users in and out, the
  remember-me cookie, fetching the current user, and the plug/LiveView
  `on_mount` hooks that guard routes by authentication state and, for the
  admin area, by role.
  """

  use CakeWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Cake.Accounts
  alias Cake.Accounts.User

  require Logger

  @must_log_in "You must log in to access this page."
  @not_authorized "You are not authorized to access this page."
  @session_ended "Your session has ended. Log in again to go on."

  # Make the remember me cookie valid for 60 days.
  # If you want bump or reduce this value, also change
  # the token expiry itself in UserToken.
  @max_age 60 * 60 * 24 * 60
  @remember_me_cookie "_cake_web_user_remember_me"
  @remember_me_options [sign: true, max_age: @max_age, same_site: "Lax"]

  @doc """
  Logs the user in.

  It renews the session ID and clears the whole session
  to avoid fixation attacks. See the renew_session
  function to customize this behaviour.

  It also sets a `:live_socket_id` key in the session,
  so LiveView sessions are identified and automatically
  disconnected on log out. The line can be safely removed
  if you are not using LiveView.
  """
  @spec log_in_user(Plug.Conn.t(), User.t(), map()) :: {:ok, Plug.Conn.t()} | {:error, :gone}
  def log_in_user(conn, user, params \\ %{}) do
    with {:ok, token} <- Accounts.generate_user_session_token(user) do
      user_return_to = get_session(conn, :user_return_to)

      {:ok,
       conn
       |> renew_session()
       |> put_token_in_session(token)
       |> maybe_write_remember_me_cookie(token, params)
       |> redirect(to: user_return_to || signed_in_path(conn))}
    end
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}) do
    put_resp_cookie(conn, @remember_me_cookie, token, @remember_me_options)
  end

  defp maybe_write_remember_me_cookie(conn, _token, _params) do
    conn
  end

  # This function renews the session ID and erases the whole
  # session to avoid fixation attacks. If there is any data
  # in the session you may want to preserve after log in/log out,
  # you must explicitly fetch the session data before clearing
  # and then immediately set it after clearing, for example:
  #
  #     defp renew_session(conn) do
  #       preferred_locale = get_session(conn, :preferred_locale)
  #
  #       conn
  #       |> configure_session(renew: true)
  #       |> clear_session()
  #       |> put_session(:preferred_locale, preferred_locale)
  #     end
  #
  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See renew_session.
  """
  @spec log_out_user(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    live_socket_id = get_session(conn, :live_socket_id)
    _ = if live_socket_id, do: CakeWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})

    conn
    |> renew_session()
    |> delete_resp_cookie(@remember_me_cookie)
    |> redirect(to: ~p"/")
  end

  @doc """
  Authenticates the user by looking into the session
  and remember me token.
  """
  @spec fetch_current_user(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def fetch_current_user(conn, _opts) do
    {user_token, conn} = ensure_user_token(conn)
    user = user_token && Accounts.get_user_by_session_token(user_token)
    assign(conn, :current_user, user)
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, put_token_in_session(conn, token)}
      else
        {nil, conn}
      end
    end
  end

  @doc """
  Handles mounting and authenticating the current_user in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_user` - Assigns current_user
      to socket assigns based on user_token, or nil if
      there's no user_token or no matching user.

    * `:ensure_authenticated` - Authenticates the user from the session,
      and assigns the current_user to socket assigns based
      on user_token.
      Redirects to login page if there's no logged user.

    * `:redirect_if_user_is_authenticated` - Authenticates the user from the session.
      Redirects to signed_in_path if there's a logged user.

    * `:ensure_admin` - Authenticates the user from the session and lets
      only an admin through. Redirects to the login page if there's no
      logged user, and to the home page, with a "not authorized" flash, if
      the user is not an admin. It does not need `:ensure_authenticated`
      before it. The user, and so the role, is read when the LiveView
      mounts, and again on every event of a connected page, so a demotion
      takes effect on the user's next navigation or next action in the
      admin area, whichever comes first.

  Every hook also subscribes a connected page of a logged-in user to that
  user's topic, so that `end_live_sessions/1` can send the page to the
  log-in page.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the current_user:

      defmodule CakeWeb.PageLive do
        use CakeWeb, :live_view

        on_mount {CakeWeb.UserAuth, :mount_current_user}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{CakeWeb.UserAuth, :ensure_authenticated}] do
        live "/profile", ProfileLive, :index
      end
  """

  @spec on_mount(atom(), map(), map(), map()) :: {:halt, map()} | {:cont, map()}
  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_current_user(socket, session)}
  end

  @spec on_mount(atom(), map(), map(), map()) :: {:halt, map()} | {:cont, map()}
  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      {:halt, halt_to_log_in(socket)}
    end
  end

  @spec on_mount(atom(), map(), map(), map()) :: {:halt, map()} | {:cont, map()}
  def on_mount(:ensure_admin, _params, session, socket) do
    socket = mount_current_user(socket, session)

    case socket.assigns.current_user do
      %User{role: :admin} ->
        {:cont, ensure_admin_on_events(socket, session)}

      %User{} ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, @not_authorized)
          |> Phoenix.LiveView.redirect(to: ~p"/")

        {:halt, socket}

      nil ->
        {:halt, halt_to_log_in(socket)}
    end
  end

  @spec on_mount(atom(), map(), map(), map()) :: {:halt, map()} | {:cont, map()}
  def on_mount(:redirect_if_user_is_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user do
      {:halt, Phoenix.LiveView.redirect(socket, to: signed_in_path(socket))}
    else
      {:cont, socket}
    end
  end

  # Whatever the page, so it says what happened rather than that the page
  # needs a log-in: it is also heard on pages anyone may open.
  defp halt_sessions_ended(socket) do
    socket
    |> Phoenix.LiveView.put_flash(:error, @session_ended)
    |> Phoenix.LiveView.redirect(to: ~p"/users/log_in")
  end

  defp halt_to_log_in(socket) do
    socket
    |> Phoenix.LiveView.put_flash(:error, @must_log_in)
    |> Phoenix.LiveView.redirect(to: ~p"/users/log_in")
  end

  defp mount_current_user(socket, session) do
    socket
    |> Phoenix.Component.assign_new(:current_user, fn -> user_of_session(session) end)
    |> leave_when_sessions_end(session)
  end

  defp user_of_session(session) do
    if user_token = session["user_token"] do
      Accounts.get_user_by_session_token(user_token)
    end
  end

  # The guard above runs when a page is opened. An admin page that is
  # already open checks again each time it is asked to do something: the
  # session is looked up afresh, so an admin who has since been demoted,
  # deleted or logged out is turned away as on a mount, and the event is
  # dropped.
  defp ensure_admin_on_events(socket, session) do
    if Phoenix.LiveView.connected?(socket) and not hooked?(socket, :ensure_admin) do
      socket
      |> mark_hooked(:ensure_admin)
      |> Phoenix.LiveView.attach_hook(:ensure_admin, :handle_event, fn _event, _params, socket ->
        ensure_admin_still(socket, session)
      end)
    else
      socket
    end
  end

  # A LiveView can run more than one of these hooks (a `live_session`'s and
  # its own, or two of its own), and a hook attached twice under one name
  # raises. Each is attached once per page, and remembered here.
  defp hooked?(socket, name), do: Map.has_key?(socket.private, {__MODULE__, name})

  defp mark_hooked(socket, name),
    do: Phoenix.LiveView.put_private(socket, {__MODULE__, name}, true)

  defp ensure_admin_still(socket, session) do
    case user_of_session(session) do
      %User{role: :admin} ->
        {:cont, socket}

      %User{} ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, @not_authorized)
          |> Phoenix.LiveView.redirect(to: ~p"/")

        {:halt, socket}

      nil ->
        {:halt, halt_to_log_in(socket)}
    end
  rescue
    # The session could not be read: the database is down, restarting, or
    # out of connections. An admin who cannot be vouched for is turned away,
    # and the page does not crash, because a crash report prints the event
    # being handled, which on a form can hold a password. The log gets what
    # failed, not the event.
    error ->
      Logger.error(
        "#{inspect(__MODULE__)}: could not read the session before an admin event: " <>
          inspect(error.__struct__)
      )

      {:halt, halt_to_log_in(socket)}
  end

  ## Ending a user's live pages

  @doc """
  Sends every live page `user` has open to the log-in page.

  Call it after the user's sessions have been deleted: when an admin sets
  their password (`Cake.Accounts.reset_user_password/2`) or deletes them
  (`Cake.Accounts.delete_user/1`). Deleting the session rows stops the next
  request and the next mount; this stops the pages that are already open,
  which would otherwise go on working until they were next navigated.

  It goes by the user, not by their session tokens, so the caller needs
  nothing back from the function that deleted them. A page that mounted
  before the rows went is subscribed and hears this, and one that mounts
  after finds no session. A page mounting at that very moment could find
  its session and subscribe too late to hear; so a mount looks the session
  up once more after it has subscribed.

  What this does not cover is a log-in in flight: a request that checked
  the old password before it was changed and stores its session after the
  others were deleted. That is `Cake.Accounts`'s to close, not this
  function's.
  """
  @spec end_live_sessions(User.t()) :: :ok
  def end_live_sessions(%User{id: id}) do
    Phoenix.PubSub.broadcast(Cake.PubSub, sessions_topic(id), {__MODULE__, :sessions_ended})
  end

  defp sessions_topic(user_id), do: "user_live_sessions:#{user_id}"

  # Every `on_mount` hook mounts the user through `mount_current_user/2`, so
  # every live page of a logged-in user listens here.
  defp leave_when_sessions_end(%{assigns: %{current_user: %User{id: id}}} = socket, session) do
    if Phoenix.LiveView.connected?(socket) and not hooked?(socket, :sessions_ended) do
      :ok = Phoenix.PubSub.subscribe(Cake.PubSub, sessions_topic(id))
      still_logged_in(socket, session)
    else
      socket
    end
  end

  defp leave_when_sessions_end(socket, _session), do: socket

  # The session was found before the page subscribed. If it ended in
  # between, the broadcast went unheard, so it is looked up once more: gone,
  # and the page mounts for nobody, which each guard then turns away.
  defp still_logged_in(socket, session) do
    case user_of_session(session) do
      %User{} ->
        socket
        |> mark_hooked(:sessions_ended)
        |> Phoenix.LiveView.attach_hook(:sessions_ended, :handle_info, fn
          {__MODULE__, :sessions_ended}, socket -> {:halt, halt_sessions_ended(socket)}
          _message, socket -> {:cont, socket}
        end)

      nil ->
        Phoenix.Component.assign(socket, :current_user, nil)
    end
  end

  @doc """
  Used for routes that require the user to not be authenticated.
  """
  @spec redirect_if_user_is_authenticated(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def redirect_if_user_is_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
      |> redirect(to: signed_in_path(conn))
      |> halt()
    else
      conn
    end
  end

  @doc """
  Used for routes that require the user to be authenticated.

  Whether the user's email is confirmed is not checked here. It is enforced
  at log-in, by `CakeWeb.UserSessionController`; taking a confirmation back
  does not end the sessions the user already has (#401).
  """
  @spec require_authenticated_user(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, @must_log_in)
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log_in")
      |> halt()
    end
  end

  @doc """
  Used for routes that only an admin may open.

  A user who is not logged in is handled as `require_authenticated_user/2`
  handles them: sent to the login page, with the path remembered. So this
  plug does not need that one before it. A logged-in user who is not an
  admin is sent to the home page with a "not authorized" flash, and their
  path is not remembered: logging in again would not let them in.

  The role is the one on `conn.assigns.current_user`, which
  `fetch_current_user/2` reads from the database on every request.
  """
  @spec require_admin(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_admin(conn, opts) do
    case conn.assigns[:current_user] do
      %User{role: :admin} ->
        conn

      %User{} ->
        conn
        |> put_flash(:error, @not_authorized)
        |> redirect(to: ~p"/")
        |> halt()

      nil ->
        require_authenticated_user(conn, opts)
    end
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  defp signed_in_path(_conn), do: ~p"/"
end
