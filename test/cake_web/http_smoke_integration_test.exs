defmodule CakeWeb.HttpSmokeIntegrationTest do
  # Every other web test drives the endpoint in-process (`Phoenix.ConnTest`,
  # `Phoenix.LiveViewTest`) with `server: false`, so no request ever crosses
  # the real HTTP stack. This suite does: the endpoint is booted with its
  # real adapter (Bandit) on an ephemeral port and spoken to over TCP, so a
  # Bandit upgrade (#206) has a gate proving the app still serves (#252).
  use Cake.HttpServerCase

  import Cake.AccountsFixtures

  describe "login round trip" do
    test "a password login sets a session cookie that authenticates the next request", ctx do
      user = user_fixture()

      login_page = Req.get!(http(ctx), url: "/users/log_in")
      assert login_page.status == 200
      anonymous_cookie = session_cookie(login_page)
      assert anonymous_cookie, "the login page set no #{session_cookie_name()} cookie"

      response =
        Req.post!(http(ctx),
          url: "/users/log_in",
          headers: [cookie: anonymous_cookie],
          form: [
            _csrf_token: csrf_token!(login_page.body),
            "user[email]": user.email,
            "user[password]": valid_user_password()
          ]
        )

      assert response.status == 302
      assert Req.Response.get_header(response, "location") == ["/"]
      user_cookie = session_cookie(response)
      assert user_cookie, "the login response set no #{session_cookie_name()} cookie"
      refute user_cookie == anonymous_cookie

      settings = Req.get!(http(ctx), url: "/users/settings", headers: [cookie: user_cookie])
      assert settings.status == 200
      assert settings.body =~ user.email
    end

    test "without the session cookie an authenticated page redirects to the login page", ctx do
      response = Req.get!(http(ctx), url: "/users/settings")

      assert response.status == 302
      assert Req.Response.get_header(response, "location") == ["/users/log_in"]
    end
  end

  describe "authenticated LiveView over a real WebSocket" do
    test "/chat mounts over /live/websocket with the logged-in session", ctx do
      cookie = log_in!(ctx, user_fixture())

      assert {:ok, rendered} = live_join!(ctx, "/chat", cookie)
      assert rendered_text(rendered) =~ "Cake Chat"
    end

    test "a join without the session's CSRF token is refused a session", ctx do
      cookie = log_in!(ctx, user_fixture())

      # The socket only hands the cookie session to the LiveView when the
      # connect carries the matching CSRF token; without it the
      # authenticated live_session redirects instead of rendering.
      assert {:error, %{"redirect" => %{"to" => "/users/log_in"}}} =
               live_join!(ctx, "/chat", cookie, csrf_token: "not-the-session-token")
    end
  end

  describe "error pages" do
    test "an unknown path renders the 404 page over HTTP", ctx do
      response = Req.get!(http(ctx), url: "/no/such/page")

      assert response.status == 404
      assert response.body =~ "Not Found"
    end
  end

  defp log_in!(ctx, user) do
    login_page = Req.get!(http(ctx), url: "/users/log_in")

    response =
      Req.post!(http(ctx),
        url: "/users/log_in",
        headers: [cookie: session_cookie(login_page)],
        form: [
          _csrf_token: csrf_token!(login_page.body),
          "user[email]": user.email,
          "user[password]": valid_user_password()
        ]
      )

    302 = response.status
    session_cookie(response)
  end
end
