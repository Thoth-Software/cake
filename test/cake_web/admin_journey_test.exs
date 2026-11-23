defmodule CakeWeb.AdminJourneyTest do
  @moduledoc """
  The admin area end to end (#373): from how a login comes to exist, through
  the real log-in form, to `/admin`.

  The other suites test each link on its own: `Cake.AccountsTest` that
  `create_user/1` makes an admin who can authenticate, the session
  controller and `UserLoginLive` tests that the form logs a user in, and
  `CakeWeb.AdminLiveTest` the guard, for a user whose session the test sets
  directly. Here nothing is set directly. A user is made the way one is
  really made (`create_user/1`, the registration page, the dev seed), logs
  in by typing a username and a password into the form, and the session
  that comes back is the one that meets the guard.

  It needs no infrastructure beyond the database, so it is an ordinary test
  and runs on every push. It is not `async`: the seed test inserts the dev
  login's fixed username.
  """

  use CakeWeb.ConnCase

  import Phoenix.LiveViewTest
  import Cake.AccountsFixtures

  alias Cake.Accounts

  @not_authorized "You are not authorized to access this page."

  # The dev login `priv/repo/seeds.exs` creates. If the seed changes its
  # username or password, `docs/architecture/web.md` and anyone's habits change
  # with it, and so does this.
  @seeded_username "admin"
  @seeded_password "adminpassword@1234"

  # Types the username and password into the log-in form and submits it, as
  # a browser does. Returns the conn of the POST, which carries the session.
  defp log_in_through_form(conn, username, password) do
    {:ok, lv, _html} = live(conn, ~p"/users/log_in")

    lv
    |> form("#login_form", user: %{username: username, password: password})
    |> submit_form(conn)
  end

  # The text content of the one element `selector` matches in the LiveView,
  # without the whitespace the template puts around it.
  defp text_of(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.text()
    |> String.trim()
  end

  test "an admin made with create_user/1 logs in through the form, opens /admin, and is turned away once demoted",
       %{conn: conn} do
    username = unique_user_username()
    password = valid_user_password()

    {:ok, admin} =
      Accounts.create_user(%{
        username: username,
        email: unique_user_email(),
        password: password,
        role: :admin
      })

    admin_fixture()

    conn = log_in_through_form(conn, username, password)
    assert redirected_to(conn) == ~p"/"

    assert {:ok, lv, _html} = live(conn, ~p"/admin")
    assert text_of(lv, "h1") == "Admin"
    assert conn |> get(~p"/admin") |> html_response(200)

    {:ok, _demoted} = Accounts.update_user_role(admin, :member)

    assert {:error, {:redirect, %{to: path, flash: flash}}} = live(conn, ~p"/admin")
    assert path == ~p"/"
    assert %{"error" => @not_authorized} = flash
  end

  test "a visitor sent to the log-in page from /admin lands back on /admin after logging in as an admin",
       %{conn: conn} do
    username = unique_user_username()
    password = valid_user_password()

    {:ok, _admin} =
      Accounts.create_user(%{
        username: username,
        email: unique_user_email(),
        password: password,
        role: :admin
      })

    turned_away = get(conn, ~p"/admin")
    assert redirected_to(turned_away) == ~p"/users/log_in"

    logged_in = log_in_through_form(turned_away, username, password)
    assert redirected_to(logged_in) == ~p"/admin"

    assert {:ok, lv, _html} = live(logged_in, ~p"/admin")
    assert text_of(lv, "h1") == "Admin"
  end

  test "someone who registers on the registration page, confirms their email and logs in is a member, and /admin turns them away",
       %{conn: conn} do
    username = unique_user_username()
    email = unique_user_email()
    password = valid_user_password()

    {:ok, lv, _html} = live(conn, ~p"/users/register")

    {:ok, _conn} =
      lv
      |> form("#registration_form", user: %{username: username, email: email, password: password})
      |> render_submit()
      |> follow_redirect(conn, ~p"/users/log_in")

    # Registering logs nobody in, and neither does the right password until
    # the email is confirmed.
    refused = log_in_through_form(conn, username, password)
    assert redirected_to(refused) == ~p"/users/log_in"
    refute get_session(refused, :user_token)

    # The link in the mail registration sent.
    assert_received {:email, %Swoosh.Email{to: [{_name, ^email}], text_body: body}}
    [_, token] = Regex.run(~r{/users/confirm/(\S+)}, body)

    {:ok, confirm_lv, _html} = live(conn, ~p"/users/confirm/#{token}")
    confirm_lv |> form("#confirmation_form") |> render_submit()

    conn = log_in_through_form(conn, username, password)
    assert redirected_to(conn) == ~p"/"

    assert {:error, {:redirect, %{to: path, flash: flash}}} = live(conn, ~p"/admin")
    assert path == ~p"/"
    assert %{"error" => @not_authorized} = flash

    request = get(conn, ~p"/admin")
    assert redirected_to(request) == ~p"/"
    assert Phoenix.Flash.get(request.assigns.flash, :error) == @not_authorized
  end

  test "the dev seed's login logs in with the seeded password and opens /admin", %{conn: conn} do
    Code.eval_file(Application.app_dir(:cake, "priv/repo/seeds.exs"))

    conn = log_in_through_form(conn, @seeded_username, @seeded_password)
    assert redirected_to(conn) == ~p"/"

    assert {:ok, lv, _html} = live(conn, ~p"/admin")
    assert text_of(lv, "h1") == "Admin"
  end

  test "nobody gets into /admin with a wrong password for an admin's username", %{conn: conn} do
    username = unique_user_username()

    {:ok, _admin} =
      Accounts.create_user(%{
        username: username,
        email: unique_user_email(),
        password: valid_user_password(),
        role: :admin
      })

    conn = log_in_through_form(conn, username, "not the password")
    assert redirected_to(conn) == ~p"/users/log_in"

    assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin")
    assert path == ~p"/users/log_in"
  end
end
