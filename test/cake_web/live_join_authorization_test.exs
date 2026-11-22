defmodule CakeWeb.LiveJoinAuthorizationTest do
  @moduledoc """
  Every access check on a Cake LiveView mount is a `live_session` hook
  (`CakeWeb.UserAuth`'s `:ensure_authenticated` and `:ensure_admin`), and
  none is declared in a LiveView module. A client that joins a router-mounted
  LiveView's channel without a `"url"` must therefore be refused: before
  phoenix_live_view 1.0.20 such a join mounted the LiveView with no route,
  and only a route loads the `live_session` hooks (EEF-CVE-2026-126334,
  #389).

  These tests talk to the LiveView channel directly, as a hand-written client
  would. `Phoenix.LiveViewTest` always sends the URL, so it cannot reach the
  case. Each test renders a page over HTTP to obtain the tokens a browser
  would hold, revokes the user's access, and then joins with and without the
  URL. A join with the URL before the revocation shows the tokens were valid.

  The module is `async: false` because one test turns off
  `config :cake, :self_service_accounts`, which is global (#367).
  """

  use CakeWeb.ConnCase, async: false

  import Cake.AccountsFixtures

  alias Cake.Accounts

  require Phoenix.ChannelTest

  describe "a router-mounted LiveView joined after access was revoked" do
    test "an admin demoted after loading /admin cannot mount it, with or without the URL",
         %{conn: conn} do
      # Two admins: the last one cannot be demoted (#373).
      _other_admin = admin_fixture()
      admin = admin_fixture()
      page = render_page(log_in_user(conn, admin), ~p"/admin")

      assert {:ok, _, _} = join_live(page, url: true)

      {:ok, _member} = Accounts.update_user_role(admin, :member)

      assert_refused(join_live(page, url: true))
      assert_refused(join_live(page, url: false))
    end

    test "a user whose session was revoked after loading /chat cannot mount it, with or without the URL",
         %{conn: conn} do
      user = user_fixture()
      page = render_page(log_in_user(conn, user), ~p"/chat")

      assert {:ok, _, _} = join_live(page, url: true)

      :ok = Accounts.delete_user_session_token(page.http_session["user_token"])

      assert_refused(join_live(page, url: true))
      assert_refused(join_live(page, url: false))
    end
  end

  describe "a page the self-service switch closes" do
    setup do
      previous = Application.fetch_env(:cake, :self_service_accounts)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:cake, :self_service_accounts, value)
          :error -> Application.delete_env(:cake, :self_service_accounts)
        end
      end)
    end

    # The page is rendered while the switch is on, which is the only way to
    # hold its tokens: with the switch off the page is never served.
    test "the registration page cannot be mounted once the switch is off, with or without the URL",
         %{conn: conn} do
      Application.put_env(:cake, :self_service_accounts, true)
      page = render_page(conn, ~p"/users/register")

      assert {:ok, _, _} = join_live(page, url: true)

      Application.put_env(:cake, :self_service_accounts, false)

      assert_refused(join_live(page, url: true))
      assert_refused(join_live(page, url: false))
    end
  end

  # What a browser holds after an HTTP render: the LiveView's DOM id, its
  # signed session and static tokens, the page's CSRF token, and the Plug
  # session the websocket would carry.
  defp render_page(conn, path) do
    conn = get(conn, path)
    {:ok, document} = conn |> html_response(200) |> Floki.parse_document()
    main = Floki.find(document, "[data-phx-main]")

    %{
      id: attribute!(main, "id"),
      session: attribute!(main, "data-phx-session"),
      static: attribute!(main, "data-phx-static"),
      csrf_token: attribute!(Floki.find(document, ~s(meta[name="csrf-token"])), "content"),
      http_session: get_session(conn),
      url: CakeWeb.Endpoint.url() <> path
    }
  end

  defp attribute!(nodes, name) do
    [value] = Floki.attribute(nodes, name)
    value
  end

  # A refusal is a join the channel answered with an error. A join whose
  # process crashed is answered with an error too, and would pass for the
  # wrong reason, so it is ruled out.
  defp assert_refused(result) do
    assert {:error, reply} = result
    refute reply == %{reason: "join crashed"}
  end

  # Joins the page's LiveView on a fresh socket, as the LiveView client does,
  # with the page URL or without it. This calls Phoenix.Channel.Server.join/4
  # the way Phoenix.ChannelTest.join/4 does, but returns the channel pid on
  # success: ChannelTest then asks the channel for its socket, a call
  # Phoenix.LiveView.Channel forwards to the LiveView, which has no
  # handle_call/3. The LiveView process stays under the test socket's
  # supervisor and stops with the test.
  defp join_live(page, url: with_url?) do
    {:ok, socket} =
      Phoenix.ChannelTest.connect(Phoenix.LiveView.Socket, %{"_csrf_token" => page.csrf_token},
        connect_info: %{session: page.http_session}
      )

    payload =
      Map.merge(
        %{
          "session" => page.session,
          "static" => page.static,
          "params" => %{"_csrf_token" => page.csrf_token, "_mounts" => 0}
        },
        if(with_url?, do: %{"url" => page.url}, else: %{})
      )

    message = %Phoenix.Socket.Message{
      event: "phx_join",
      topic: "lv:" <> page.id,
      payload: payload,
      ref: "1"
    }

    %Phoenix.Socket{private: %{phoenix_test_supervisor: supervisor}} = socket

    starter = fn _socket, _from, spec ->
      Supervisor.start_child(supervisor, %{spec | id: make_ref()})
    end

    Phoenix.Channel.Server.join(socket, Phoenix.LiveView.Channel, message, starter: starter)
  end
end
