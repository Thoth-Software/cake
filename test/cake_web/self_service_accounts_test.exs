defmodule CakeWeb.SelfServiceAccountsTest do
  @moduledoc """
  The contract of `config :cake, :self_service_accounts` when it is `false`
  (#367): registration, password reset by mail, confirmation by mail and the
  email change are closed, logins are an administrator's to make, and no
  page sends mail.

  With the switch on, nothing differs from before it existed. That side is
  pinned by the account pages' own tests, which run with the default and
  were not changed.

  The switch is application config, which is global, so this module is
  `async: false`: it turns the switch off for each test and puts back what
  was there afterwards.
  """

  use CakeWeb.ConnCase, async: false

  import Cake.AccountsFixtures
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Cake.Accounts
  alias Cake.Accounts.User
  alias Cake.Accounts.UserToken
  alias Cake.Repo
  alias CakeWeb.UserAuth
  alias Phoenix.LiveView

  @managed "managed by an administrator"

  setup do
    previous = Application.fetch_env(:cake, :self_service_accounts)
    Application.put_env(:cake, :self_service_accounts, false)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:cake, :self_service_accounts, value)
        :error -> Application.delete_env(:cake, :self_service_accounts)
      end
    end)
  end

  describe "self_service_accounts?/0" do
    test "is false when the switch is off" do
      refute UserAuth.self_service_accounts?()
    end

    test "is true when the switch is on, and when it was never set" do
      Application.put_env(:cake, :self_service_accounts, true)
      assert UserAuth.self_service_accounts?()

      Application.delete_env(:cake, :self_service_accounts)
      assert UserAuth.self_service_accounts?()
    end
  end

  describe "require_self_service_accounts/2" do
    setup %{conn: conn} do
      %{conn: conn |> init_test_session(%{}) |> fetch_flash()}
    end

    test "lets the request through when the switch is on", %{conn: conn} do
      Application.put_env(:cake, :self_service_accounts, true)

      conn = UserAuth.require_self_service_accounts(conn, [])

      refute conn.halted
      refute conn.status
    end

    test "sends a visitor to the log-in page", %{conn: conn} do
      conn = conn |> assign(:current_user, nil) |> UserAuth.require_self_service_accounts([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/users/log_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ @managed
    end

    test "sends a signed-in user to the home page", %{conn: conn} do
      conn =
        conn
        |> assign(:current_user, user_fixture())
        |> UserAuth.require_self_service_accounts([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ @managed
    end

    test "sends a signed-in user where :signed_in_to says", %{conn: conn} do
      conn =
        conn
        |> assign(:current_user, user_fixture())
        |> UserAuth.require_self_service_accounts(signed_in_to: ~p"/users/settings")

      assert conn.halted
      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ @managed
    end

    test "does not remember the path a visitor asked for", %{conn: conn} do
      conn =
        %{conn | method: "GET", request_path: "/users/register"}
        |> assign(:current_user, nil)
        |> UserAuth.require_self_service_accounts([])

      refute get_session(conn, :user_return_to)
    end
  end

  describe "on_mount :ensure_self_service_accounts" do
    setup %{conn: conn} do
      socket = %LiveView.Socket{
        endpoint: CakeWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      %{conn: init_test_session(conn, %{}), socket: socket}
    end

    test "lets the mount through when the switch is on, with current_user assigned",
         %{conn: conn, socket: socket} do
      Application.put_env(:cake, :self_service_accounts, true)
      user = user_fixture()

      assert {:cont, signed_in} =
               UserAuth.on_mount(
                 :ensure_self_service_accounts,
                 %{},
                 session_of(conn, user),
                 socket
               )

      assert signed_in.assigns.current_user.id == user.id

      assert {:cont, visitor} =
               UserAuth.on_mount(:ensure_self_service_accounts, %{}, get_session(conn), socket)

      assert visitor.assigns.current_user == nil
    end

    test "halts a visitor's mount and sends them to the log-in page",
         %{conn: conn, socket: socket} do
      assert {:halt, socket} =
               UserAuth.on_mount(:ensure_self_service_accounts, %{}, get_session(conn), socket)

      assert {:redirect, %{to: "/users/log_in"}} = socket.redirected
      assert socket.assigns.flash["error"] =~ @managed
    end

    test "halts a signed-in user's mount and sends them to the home page",
         %{conn: conn, socket: socket} do
      session = session_of(conn, user_fixture())

      assert {:halt, socket} =
               UserAuth.on_mount(:ensure_self_service_accounts, %{}, session, socket)

      assert {:redirect, %{to: "/"}} = socket.redirected
      assert socket.assigns.flash["error"] =~ @managed
    end

    test "halts a signed-in user's mount and sends them where :signed_in_to says",
         %{conn: conn, socket: socket} do
      session = session_of(conn, user_fixture())
      hook = {:ensure_self_service_accounts, signed_in_to: ~p"/users/settings"}

      assert {:halt, socket} = UserAuth.on_mount(hook, %{}, session, socket)

      assert {:redirect, %{to: "/users/settings"}} = socket.redirected
      assert socket.assigns.flash["error"] =~ @managed
    end
  end

  describe "the closed pages, for a visitor" do
    test "none mounts: each sends the visitor to the log-in page and writes nothing",
         %{conn: conn} do
      before = counts()

      for path <- [
            ~p"/users/register",
            ~p"/users/reset_password",
            ~p"/users/reset_password/some-token",
            ~p"/users/confirm",
            ~p"/users/confirm/some-token"
          ] do
        assert_closed(live(conn, path), ~p"/users/log_in")
        assert_closed_over_http(get(conn, path), ~p"/users/log_in")
      end

      assert counts() == before
    end

    test "a valid reset-password token opens nothing, and the password stands", %{conn: conn} do
      user = user_fixture()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_reset_password_instructions(user, url)
        end)

      assert_closed(live(conn, ~p"/users/reset_password/#{token}"), ~p"/users/log_in")

      assert Accounts.get_user_by_username_and_password(user.username, valid_user_password())
      assert Repo.get_by(UserToken, user_id: user.id, context: "reset_password")
    end

    test "a valid confirmation token confirms nobody", %{conn: conn} do
      user = unconfirmed_user_fixture()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      assert_closed(live(conn, ~p"/users/confirm/#{token}"), ~p"/users/log_in")

      assert is_nil(Repo.get!(User, user.id).confirmed_at)
      assert Repo.get_by(UserToken, user_id: user.id, context: "confirm")
    end
  end

  describe "the closed pages, for a signed-in user" do
    test "the two confirmation pages send the user to the home page and write nothing",
         %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      before = counts()

      for path <- [~p"/users/confirm", ~p"/users/confirm/some-token"] do
        assert_closed(live(conn, path), ~p"/")
        assert_closed_over_http(get(conn, path), ~p"/")
      end

      assert counts() == before
    end

    test "a valid confirmation token confirms nobody", %{conn: conn} do
      user = unconfirmed_user_fixture()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      assert_closed(conn |> log_in_user(user) |> live(~p"/users/confirm/#{token}"), ~p"/")

      assert is_nil(Repo.get!(User, user.id).confirmed_at)
      assert Repo.get_by(UserToken, user_id: user.id, context: "confirm")
    end

    # The pages only a visitor may open turn a signed-in user away as they
    # always did, switch or no switch.
    test "the visitor-only pages still send a signed-in user to the home page", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())

      for path <- [
            ~p"/users/register",
            ~p"/users/reset_password",
            ~p"/users/reset_password/some-token"
          ] do
        assert {:error, {:redirect, %{to: "/"}}} = live(conn, path)
      end
    end
  end

  describe "the email-change link" do
    setup do
      user = user_fixture()
      new_email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(
            %{user | email: new_email},
            user.email,
            url
          )
        end)

      %{user: user, new_email: new_email, token: token}
    end

    test "sends a signed-in user back to settings, and a valid token changes no email",
         %{conn: conn, user: user, new_email: new_email, token: token} do
      conn = log_in_user(conn, user)
      path = ~p"/users/settings/confirm_email/#{token}"

      assert_closed(live(conn, path), ~p"/users/settings")
      assert_closed_over_http(get(conn, path), ~p"/users/settings")

      assert Repo.get!(User, user.id).email == user.email
      refute Accounts.get_user_by_email(new_email)
      assert Repo.get_by(UserToken, user_id: user.id, context: "change:#{user.email}")
    end

    test "still asks a visitor to log in, and changes no email",
         %{conn: conn, user: user, token: token} do
      assert {:error, {:redirect, %{to: "/users/log_in", flash: flash}}} =
               live(conn, ~p"/users/settings/confirm_email/#{token}")

      assert %{"error" => "You must log in to access this page."} = flash
      assert Repo.get!(User, user.id).email == user.email
    end
  end

  describe "the log-in page" do
    test "opens, with its form and none of the links to a closed page", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log_in")

      assert has_element?(lv, "#login_form")
      refute has_element?(lv, ~s|a[href="/users/register"]|)
      refute has_element?(lv, ~s|a[href="/users/reset_password"]|)
      refute has_element?(lv, ~s|a[href="/users/confirm"]|)
      refute has_element?(lv, "#resend-confirmation-link")
    end

    test "still logs a confirmed user in", %{conn: conn} do
      user = user_fixture()

      conn =
        post(conn, ~p"/users/log_in", %{
          "user" => %{"username" => user.username, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "the shell's guest menu" do
    test "offers to log in and not to register, on the home page and the log-in page",
         %{conn: conn} do
      for path <- [~p"/", ~p"/users/log_in"] do
        document = conn |> get(path) |> html_response(200) |> Floki.parse_document!()

        assert [_log_in] = Floki.find(document, ~s|#guest-menu a[href="/users/log_in"]|)
        assert [] == Floki.find(document, ~s|a[href="/users/register"]|)
      end
    end
  end

  describe "the log-in refusal for an unconfirmed user" do
    # Nothing was sent, so the refusal names no link. As with the switch on,
    # it says why only to someone who has the password.
    test "says the login is not confirmed and whom to ask, and mentions no mail", %{conn: conn} do
      user = unconfirmed_user_fixture()

      refused =
        post(conn, ~p"/users/log_in", %{
          "user" => %{"username" => user.username, "password" => valid_user_password()}
        })

      refute get_session(refused, :user_token)
      assert redirected_to(refused) == ~p"/users/log_in"

      message = Phoenix.Flash.get(refused.assigns.flash, :error)
      assert message =~ "not confirmed"
      assert message =~ "Ask"
      refute message =~ "link"
      refute message =~ "sent"
      refute message =~ "email"
    end

    test "is the usual answer when the password is wrong", %{conn: conn} do
      user = unconfirmed_user_fixture()

      refused =
        post(conn, ~p"/users/log_in", %{
          "user" => %{"username" => user.username, "password" => "not the password"}
        })

      refute get_session(refused, :user_token)
      assert Phoenix.Flash.get(refused.assigns.flash, :error) == "Invalid username or password"
    end
  end

  describe "the settings page" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "opens with the password form and without the email form", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      assert has_element?(lv, "#settings-username", user.username)
      assert has_element?(lv, "#password_form")
      refute has_element?(lv, "#email_form")
      refute has_element?(lv, "#settings-subtitle", "email")
    end

    # Hiding the form is not enough: a hand-written client can still send
    # the form's events.
    test "refuses update_email: no email changes, no token is made, the page stays up",
         %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")
      before = counts()

      html =
        render_hook(lv, "update_email", %{
          "current_password" => valid_user_password(),
          "user" => %{"email" => unique_user_email()}
        })

      refute html =~ "A link to confirm your email change"
      refute has_element?(lv, "#email_form")
      assert has_element?(lv, "#password_form")
      assert counts() == before
      assert Repo.get!(User, user.id).email == user.email
      refute Repo.get_by(UserToken, user_id: user.id, context: "change:#{user.email}")
    end

    test "refuses validate_email: nothing is rendered for it, the page stays up", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      _html =
        render_hook(lv, "validate_email", %{
          "current_password" => valid_user_password(),
          "user" => %{"email" => "with spaces"}
        })

      refute has_element?(lv, "#email_form")
      assert has_element?(lv, "#password_form")
    end

    test "the password form works as it does with the switch on", %{conn: conn, user: user} do
      new_password = valid_user_password() <> " and more"

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      form =
        form(lv, "#password_form", %{
          "current_password" => valid_user_password(),
          "user" => %{
            "username" => user.username,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/users/settings"
      assert get_session(new_password_conn, :user_token) != get_session(conn, :user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_user_by_username_and_password(user.username, new_password)
    end
  end

  describe "mail" do
    # Once, across every closed route and both refused events, with real
    # users and valid tokens.
    test "no page sends any", %{conn: conn} do
      user = user_fixture()
      unconfirmed = unconfirmed_user_fixture()

      confirm_token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(unconfirmed, url)
        end)

      reset_token =
        extract_user_token(fn url ->
          Accounts.deliver_user_reset_password_instructions(user, url)
        end)

      change_token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(
            %{user | email: unique_user_email()},
            user.email,
            url
          )
        end)

      # The three the fixtures above sent, so that none is left to be
      # mistaken for a page's.
      for _ <- 1..3, do: assert_email_sent()
      assert_no_email_sent()

      signed_in = log_in_user(conn, user)

      for {conn, path} <- [
            {conn, ~p"/users/register"},
            {conn, ~p"/users/reset_password"},
            {conn, ~p"/users/reset_password/#{reset_token}"},
            {conn, ~p"/users/confirm"},
            {conn, ~p"/users/confirm/#{confirm_token}"},
            {signed_in, ~p"/users/confirm"},
            {signed_in, ~p"/users/confirm/#{confirm_token}"},
            {signed_in, ~p"/users/settings/confirm_email/#{change_token}"}
          ] do
        assert {:error, {:redirect, _}} = live(conn, path)
      end

      {:ok, lv, _html} = live(signed_in, ~p"/users/settings")

      for event <- ["validate_email", "update_email"] do
        render_hook(lv, event, %{
          "current_password" => valid_user_password(),
          "user" => %{"email" => unique_user_email()}
        })
      end

      # A refused log-in, which names a confirmation and must not send one.
      post(conn, ~p"/users/log_in", %{
        "user" => %{"username" => unconfirmed.username, "password" => valid_user_password()}
      })

      assert_no_email_sent()
    end
  end

  describe "the admin panel" do
    # Everything behind a log-in is outside the switch. The panel's own
    # tests pin what it does (`CakeWeb.AdminJourneyTest`, with the switch
    # on); this pins that the form that makes a login still opens.
    test "still opens the form that makes a login", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in_user(admin_fixture()) |> live(~p"/admin/users/new")

      assert has_element?(lv, ~s|input[name="user[username]"]|)
    end
  end

  # A closed page seen through LiveViewTest: the mount is refused with a
  # redirect that carries the notice.
  defp assert_closed(result, to) do
    assert {:error, {:redirect, %{to: ^to, flash: flash}}} = result
    assert flash["error"] =~ @managed
  end

  # The same page as a plain HTTP request, which only the plug sees.
  defp assert_closed_over_http(conn, to) do
    assert redirected_to(conn) == to
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ @managed
  end

  defp counts do
    %{users: Repo.aggregate(User, :count), tokens: Repo.aggregate(UserToken, :count)}
  end

  defp session_of(conn, user) do
    conn
    |> put_session(:user_token, Accounts.generate_user_session_token(user))
    |> get_session()
  end
end
