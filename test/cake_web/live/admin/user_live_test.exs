defmodule CakeWeb.Admin.UserLiveTest do
  @moduledoc """
  The admin panel for logins (#376): the list at `/admin/users`, the form
  that creates a login and the one that changes it, the separate action that
  sets a password, and deletion.

  Every login has an email, and a login cannot log in until its email is
  confirmed (#377). The panel takes the email when it creates and edits a
  login, shows it and whether it is confirmed, and confirms a login or takes
  the confirmation back by hand.

  The screens are `CakeWeb.Admin.UserLive.Index`, `.Show` and `.Form`. What
  each context function does on its own is in `Cake.AccountsTest`; this is
  what an admin can do from a page, and what the page refuses.

  Three things hold on every screen:

    * a password is typed in and never comes back: not into the page, not
      into a URL, not into the log;
    * a refusal is shown on the page, as an error on the field it is about
      or as a notice, and nothing crashes;
    * only an admin gets in, and only an admin can act: a member and a
      visitor are turned away as `/admin` turns them away (#373), and an
      admin who is demoted while a screen is open can do nothing more from
      it.

  It is not `async`: one test lowers the logger's level, which is global, to
  see what a form submission logs.
  """

  use CakeWeb.ConnCase

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Cake.AccountsFixtures

  alias Cake.Accounts
  alias Cake.Accounts.User
  alias Cake.Accounts.UserToken
  alias Cake.Repo

  @not_authorized "You are not authorized to access this page."
  @must_log_in "You must log in to access this page."

  @too_short "should be at least 12 character(s)"
  @taken "has already been taken"
  @last_admin "cannot be changed: this is the last admin"
  @own_login "You cannot delete your own login."
  @gone "That login no longer exists."
  @own_confirmation "You cannot take back your own confirmation."
  @own_confirming "You cannot confirm your own email."

  # A password no fixture uses and no page has a reason to contain, so
  # finding it anywhere means it was put there.
  @typed_password "correct horse battery staple"

  # A login as the panel makes one: a username, an email, a password and a
  # role. Confirmed, as `Cake.Accounts.create_user/1` makes every login.
  defp login_fixture(role, attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        username: unique_user_username(),
        email: unique_user_email(),
        password: valid_user_password(),
        role: role
      })
      |> Accounts.create_user()

    user
  end

  defp log_in_admin(%{conn: conn}) do
    admin = login_fixture(:admin)
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  # The text content of the one element `selector` matches in the LiveView,
  # with runs of whitespace collapsed. `element/2` raises unless exactly one
  # element matches.
  defp text_of(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.text(sep: " ")
    |> String.split()
    |> Enum.join(" ")
  end

  defp column_labels(lv) do
    lv
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("thead th")
    |> Enum.map(&String.trim(Floki.text(&1)))
  end

  defp row_ids(lv) do
    lv |> render() |> Floki.parse_document!() |> Floki.attribute("#users > tr", "id")
  end

  # Every login but `user`, for a test that needs to know the whole list.
  defp from_other_than(%User{id: id}), do: from(u in User, where: u.id != ^id)

  # A crash report prints a form event as the browser sent it: URL-encoded,
  # so "correct horse" is "correct+horse" there. A log is clean of a
  # password only if it holds it in neither spelling.
  defp refute_logged(log, password) do
    for spelling <- [password, URI.encode_www_form(password), URI.encode(password)] do
      refute log =~ spelling
    end
  end

  # Makes every query that reads a session fail, as a database that is down
  # or restarting does. The sandbox puts the table back after the test.
  defp break_sessions_table do
    Repo.query!("ALTER TABLE users_tokens RENAME TO users_tokens_unreachable")
  end

  # Makes saving a login raise in the context, past its validations, with
  # the session lookup still working.
  defp break_saving_logins do
    Repo.query!(
      "ALTER TABLE users ADD CONSTRAINT nobody_saves CHECK (updated_at < '2000-01-01') NOT VALID"
    )
  end

  defp created_on(%User{inserted_at: inserted_at}), do: Calendar.strftime(inserted_at, "%Y-%m-%d")

  # Whether the log-in form, in a browser of its own, logs this username in:
  # the password has to be right and the email confirmed (#377).
  defp can_log_in?(username, password) do
    Phoenix.ConnTest.build_conn()
    |> post(~p"/users/log_in", %{"user" => %{"username" => username, "password" => password}})
    |> get_session(:user_token)
    |> is_binary()
  end

  # A second browser: `user`, logged in, with a live page open.
  defp open_page_as(user) do
    token = Accounts.generate_user_session_token(user)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, token)

    {:ok, lv, _html} = live(conn, ~p"/search")
    %{token: token, lv: lv}
  end

  describe "the list" do
    setup :log_in_admin

    test "shows each login's username, email, role, confirmation and created date, in username order, in the wide column",
         %{conn: conn, admin: admin} do
      Repo.delete_all(from_other_than(admin))
      # Capital Z sorts before every lowercase letter by bytes, and last
      # when letter case is ignored.
      zoe = login_fixture(:member, %{username: "Zoe"})
      abe = login_fixture(:admin, %{username: "abe"})
      new = unconfirmed_user_fixture(%{username: "newcomer"})

      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      assert text_of(lv, "h1") == "Logins"
      assert has_element?(lv, ~s|#page[data-width="wide"]|)

      assert column_labels(lv) ==
               ["Username", "Email", "Role", "Confirmed", "Created", "Actions"]

      assert row_ids(lv) == Enum.map([abe, admin, new, zoe], &"users-#{&1.id}")

      assert text_of(lv, "#users-#{zoe.id}") =~
               "Zoe #{zoe.email} member Confirmed #{created_on(zoe)}"

      assert text_of(lv, "#users-#{abe.id}") =~
               "abe #{abe.email} admin Confirmed #{created_on(abe)}"

      assert text_of(lv, "#users-#{new.id}") =~
               "newcomer #{new.email} member Not confirmed #{created_on(new)}"
    end

    test "never shows a password hash", %{conn: conn, admin: admin} do
      {:ok, _lv, html} = live(conn, ~p"/admin/users")

      refute html =~ admin.hashed_password
      refute html =~ "$2b$"
    end

    # Every login has an email now (#377), so the column is always there.
    # On a phone the table keeps the username, the role and Delete.
    test "drops the email, the confirmation and the created date on a phone", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      headings =
        lv
        |> render()
        |> Floki.parse_document!()
        |> Floki.find("thead th")
        |> Map.new(fn th -> {String.trim(Floki.text(th)), Floki.attribute(th, "class")} end)

      for label <- ["Email", "Confirmed", "Created"] do
        assert [classes] = headings[label]
        assert "hidden" in String.split(classes), label
      end

      for label <- ["Username", "Role"] do
        refute "hidden" in String.split(Enum.join(headings[label], " ")), label
      end
    end

    test "leads to a login's own page, to its form, and to the form for a new one",
         %{conn: conn} do
      member = login_fixture(:member)
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      assert has_element?(lv, ~s|#users-#{member.id} a[href="/admin/users/#{member.id}"]|)

      assert has_element?(
               lv,
               ~s|#users-#{member.id} a#edit-#{member.id}[href="/admin/users/#{member.id}/edit"]|
             )

      assert {:ok, form, _html} =
               lv
               |> element("#new-login")
               |> render_click()
               |> follow_redirect(conn, ~p"/admin/users/new")

      assert text_of(form, "h1") == "New login"
    end
  end

  describe "a login's page" do
    setup :log_in_admin

    test "shows the username, email, role, confirmation and created date, and leads to the form and to setting a password",
         %{conn: conn} do
      member = login_fixture(:member)
      {:ok, lv, html} = live(conn, ~p"/admin/users/#{member}")

      assert text_of(lv, "h1") == member.username
      assert page_title(lv) =~ member.username

      assert text_of(lv, "#login") =~
               "Username #{member.username} Email #{member.email} Role member " <>
                 "Confirmed yes Created #{created_on(member)}"

      refute html =~ member.hashed_password

      assert has_element?(
               lv,
               ~s|a#edit-login[href="/admin/users/#{member.id}/edit?return_to=show"]|
             )

      assert has_element?(lv, ~s|a#set-password[href="/admin/users/#{member.id}/password"]|)
    end
  end

  describe "a login that no longer exists" do
    setup :log_in_admin

    test "sends the admin back to the list, saying so, from its page and from both its forms",
         %{conn: conn} do
      member = login_fixture(:member)
      {:ok, _deleted} = Accounts.delete_user(member)

      for path <- [
            ~p"/admin/users/#{member}",
            ~p"/admin/users/#{member}/edit",
            ~p"/admin/users/#{member}/password",
            ~p"/admin/users/not-an-id",
            ~p"/admin/users/not-an-id/edit"
          ] do
        assert {:error, {:live_redirect, %{to: "/admin/users", flash: flash}}} = live(conn, path),
               path

        assert %{"error" => @gone} = flash, path
        assert conn |> get(path) |> redirected_to() == ~p"/admin/users", path
      end
    end
  end

  # A login cannot log in until its email is confirmed (#377). The admin can
  # confirm it by hand, from the login's page, and take the confirmation
  # back. Taking it back ends no session the login already has: that is
  # #401's, and nothing here pins it either way.
  describe "confirming a login by hand" do
    setup :log_in_admin

    test "confirms a login that is not confirmed, which can then log in", %{conn: conn} do
      newcomer = unconfirmed_user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{newcomer}")

      assert text_of(lv, "#login") =~ "Confirmed no"
      refute can_log_in?(newcomer.username, valid_user_password())
      refute has_element?(lv, "#unconfirm-login")

      lv |> element("#confirm-login") |> render_click()

      assert text_of(lv, "#login") =~ "Confirmed yes"
      assert has_element?(lv, "#flash-info", "Email confirmed")
      assert can_log_in?(newcomer.username, valid_user_password())
      refute has_element?(lv, "#confirm-login")
    end

    test "takes a confirmation back, behind a confirmation, and the login can no longer log in",
         %{conn: conn} do
      member = login_fixture(:member)
      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{member}")

      assert lv |> element("#unconfirm-login") |> render() =~ "data-confirm="

      lv |> element("#unconfirm-login") |> render_click()

      assert text_of(lv, "#login") =~ "Confirmed no"
      assert has_element?(lv, "#flash-info", "Confirmation taken back")
      refute can_log_in?(member.username, valid_user_password())
      assert has_element?(lv, "#confirm-login")
    end

    test "offers no way to take back the admin's own confirmation, and refuses a request for it with a notice",
         %{conn: conn, admin: admin} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{admin}")

      refute has_element?(lv, "#unconfirm-login")

      render_click(lv, "unconfirm", %{})

      assert text_of(lv, "#login-refusal [data-part=body]") == @own_confirmation
      assert has_element?(lv, "#login-refusal.alert-error")
      assert can_log_in?(admin.username, valid_user_password())
    end

    # An admin whose confirmation another admin took back keeps the sessions
    # they have (#401), and could otherwise put it back from their own page.
    test "offers an admin no way to confirm their own email, and refuses a request for it with a notice",
         %{conn: conn, admin: admin} do
      {:ok, _} = Accounts.set_user_confirmed(:operator, admin, false)
      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{admin}")

      assert text_of(lv, "#login") =~ "Confirmed no"
      refute has_element?(lv, "#confirm-login")

      render_click(lv, "confirm", %{})

      assert text_of(lv, "#login-refusal [data-part=body]") == @own_confirming
      refute Accounts.get_user!(admin.id).confirmed_at
    end

    test "sends the admin back to the list, saying so, for a login deleted meanwhile",
         %{conn: conn} do
      newcomer = unconfirmed_user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{newcomer}")
      {:ok, _deleted} = Accounts.delete_user(newcomer)

      assert {:ok, index, _html} =
               lv
               |> element("#confirm-login")
               |> render_click()
               |> follow_redirect(conn, ~p"/admin/users")

      assert has_element?(index, "#flash-error", @gone)
    end

    test "an admin demoted while the page is open confirms nothing from it", %{conn: conn} do
      admin = login_fixture(:admin)
      login_fixture(:admin)
      newcomer = unconfirmed_user_fixture()
      {:ok, lv, _html} = conn |> log_in_user(admin) |> live(~p"/admin/users/#{newcomer}")

      {:ok, _demoted} = Accounts.update_user_role(admin, :member)

      render_click(lv, "confirm", %{})

      assert_redirect(lv, ~p"/")
      refute Accounts.get_user!(newcomer.id).confirmed_at
    end
  end

  describe "creating a login" do
    setup :log_in_admin

    test "takes a username, an email, a password and a role, and the login works at once",
         %{conn: conn} do
      username = unique_user_username()
      {:ok, lv, _html} = live(conn, ~p"/admin/users/new")

      # The redirect is to the bare list: nothing typed is carried in a URL.
      assert {:ok, index, _html} =
               lv
               |> form("#user-form",
                 user: %{
                   username: username,
                   email: unique_user_email(),
                   password: @typed_password,
                   role: "member"
                 }
               )
               |> render_submit()
               |> follow_redirect(conn, ~p"/admin/users")

      assert %User{role: :member, email: email} = user = Repo.get_by!(User, username: username)
      assert email =~ "@example.com"
      # Confirmed from the start: the admin vouches for the login (#377).
      assert user.confirmed_at
      assert can_log_in?(username, @typed_password)

      assert has_element?(index, "#flash-info", "Login created")
      assert text_of(index, "#users-#{user.id}") =~ "#{username} #{email} member"
      refute render(index) =~ @typed_password
    end

    test "makes an admin when asked to", %{conn: conn} do
      username = unique_user_username()
      {:ok, lv, _html} = live(conn, ~p"/admin/users/new")

      lv
      |> form("#user-form",
        user: %{
          username: username,
          email: unique_user_email(),
          password: @typed_password,
          role: "admin"
        }
      )
      |> render_submit()

      assert %User{role: :admin} = Repo.get_by!(User, username: username)
    end

    test "holds the password to the length rule, and never renders what was typed back",
         %{conn: conn} do
      username = unique_user_username()
      short = "2-sh0rt!"
      {:ok, lv, _html} = live(conn, ~p"/admin/users/new")

      changed =
        lv
        |> form("#user-form",
          user: %{username: username, email: unique_user_email(), password: short, role: "member"}
        )
        |> render_change()

      assert changed =~ @too_short
      refute changed =~ short

      submitted =
        lv
        |> form("#user-form",
          user: %{username: username, email: unique_user_email(), password: short, role: "member"}
        )
        |> render_submit()

      assert submitted =~ @too_short
      refute submitted =~ short
      refute Repo.get_by(User, username: username)

      # A valid password is not rendered back either, when something else
      # keeps the form on the page.
      rejected =
        lv
        |> form("#user-form",
          user: %{
            username: "x",
            email: unique_user_email(),
            password: @typed_password,
            role: "member"
          }
        )
        |> render_submit()

      refute rejected =~ @typed_password
    end

    test "requires the email, and holds it to the rules registration does", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users/new")
      username = unique_user_username()

      for {email, error} <- [
            {"", "can&#39;t be blank"},
            {"no-at-sign", "must have the @ sign and no spaces"}
          ] do
        html =
          lv
          |> form("#user-form",
            user: %{username: username, email: email, password: @typed_password, role: "member"}
          )
          |> render_submit()

        assert html =~ error, email
      end

      refute Repo.get_by(User, username: username)
    end

    test "refuses an email another login has, whatever its letter case, as an error on the field",
         %{conn: conn, admin: admin} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users/new")
      username = unique_user_username()

      html =
        lv
        |> form("#user-form",
          user: %{
            username: username,
            email: String.upcase(admin.email),
            password: @typed_password,
            role: "member"
          }
        )
        |> render_submit()

      assert html =~ @taken
      refute Repo.get_by(User, username: username)
    end

    # `return_to` belongs to the edit form. A new login has no page of its
    # own to go back to.
    test "ignores a return_to in the address", %{conn: conn} do
      username = unique_user_username()
      {:ok, lv, _html} = live(conn, ~p"/admin/users/new?return_to=show")

      assert {:ok, _index, _html} =
               lv
               |> form("#user-form",
                 user: %{
                   username: username,
                   email: unique_user_email(),
                   password: @typed_password,
                   role: "member"
                 }
               )
               |> render_submit()
               |> follow_redirect(conn, ~p"/admin/users")
    end

    test "refuses a username that is taken, whatever its letter case, as an error on the field",
         %{conn: conn, admin: admin} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users/new")

      html =
        lv
        |> form("#user-form",
          user: %{
            username: String.upcase(admin.username),
            email: unique_user_email(),
            password: @typed_password,
            role: "member"
          }
        )
        |> render_submit()

      assert html =~ @taken
      assert Repo.aggregate(User, :count) == 1
    end

    test "logs neither the password typed nor the one submitted", %{conn: conn} do
      username = unique_user_username()
      {:ok, lv, _html} = live(conn, ~p"/admin/users/new")

      attrs = %{
        username: username,
        email: unique_user_email(),
        password: @typed_password,
        role: "member"
      }

      # The level is global, and lowered only while the log is captured, so
      # nothing logged at it reaches the console.
      level = Logger.level()

      log =
        capture_log(fn ->
          Logger.configure(level: :debug)

          try do
            lv |> form("#user-form", user: attrs) |> render_change()
            lv |> form("#user-form", user: attrs) |> render_submit()
          after
            Logger.configure(level: level)
          end
        end)

      # The submission was logged, with the username in it and the password
      # filtered out of it.
      assert Repo.get_by(User, username: username)
      assert log =~ username
      assert log =~ "[FILTERED]"
      refute_logged(log, @typed_password)
    end
  end

  # A page that crashes writes a report: the message it was handling and
  # everything it held. Phoenix's parameter filter does not reach either, so
  # a form that takes a password must hold none, and must not crash while
  # handling one.
  describe "a password and the crash report" do
    setup :log_in_admin

    # Everything the page holds, printed as a crash report may print it:
    # without the `Inspect` implementations that redact a field.
    defp held_by(lv) do
      inspect(:sys.get_state(lv.pid),
        limit: :infinity,
        printable_limit: :infinity,
        structs: false
      )
    end

    test "the new-login form holds no password, after typing and after a refused save", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/admin/users/new")
      attrs = %{username: "x", password: @typed_password, role: "member"}

      lv |> form("#user-form", user: attrs) |> render_change()
      refute held_by(lv) =~ @typed_password

      lv |> form("#user-form", user: attrs) |> render_submit()
      refute held_by(lv) =~ @typed_password
    end

    test "the password form holds no password, after typing and after a refused save", %{
      conn: conn
    } do
      member = login_fixture(:member)
      short = "2-sh0rt!"
      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{member}/password")

      lv |> form("#password-form", user: %{password: short}) |> render_change()
      refute held_by(lv) =~ short

      lv |> form("#password-form", user: %{password: short}) |> render_submit()
      refute held_by(lv) =~ short
    end

    test "setting a password for a login deleted meanwhile says so, goes back to the list, and logs no password",
         %{conn: conn} do
      member = login_fixture(:member)
      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{member}/password")
      {:ok, _deleted} = Accounts.delete_user(member)

      {result, log} =
        with_log(fn ->
          lv |> form("#password-form", user: %{password: @typed_password}) |> render_submit()
        end)

      assert {:ok, index, _html} = follow_redirect(result, conn, ~p"/admin/users")
      assert has_element?(index, "#flash-error", @gone)
      refute_logged(log, @typed_password)
    end

    # Whatever goes wrong while a password is being saved, the page says it
    # failed and stays up. The failure is logged, without the message that
    # caused it.
    test "a save that raises is reported on the page and in the log, without the password",
         %{conn: conn} do
      member = login_fixture(:member)
      {:ok, new, _html} = live(conn, ~p"/admin/users/new")
      {:ok, password, _html} = live(conn, ~p"/admin/users/#{member}/password")
      break_saving_logins()

      {html, log} =
        with_log(fn ->
          new
          |> form("#user-form",
            user: %{
              username: unique_user_username(),
              email: unique_user_email(),
              password: @typed_password,
              role: "member"
            }
          )
          |> render_submit()
        end)

      assert html =~ "could not be saved"
      assert has_element?(new, "#user-form")
      assert log =~ "CakeWeb.Admin.UserLive.Form"
      refute_logged(log, @typed_password)

      {password_html, password_log} =
        with_log(fn ->
          password
          |> form("#password-form", user: %{password: @typed_password})
          |> render_submit()
        end)

      assert password_html =~ "could not be saved"
      refute_logged(password_log, @typed_password)
    end

    # The admin check runs before the form sees an event, and it reads the
    # database. When that read fails the page must not crash with the event
    # in its report: it turns the admin away, as for a session it cannot
    # vouch for, and logs what failed without the event.
    test "a database that cannot be read while a password is typed or saved turns the admin away and logs no password",
         %{conn: conn} do
      member = login_fixture(:member)
      {:ok, typing, _html} = live(conn, ~p"/admin/users/new")
      {:ok, saving, _html} = live(conn, ~p"/admin/users/#{member}/password")
      break_sessions_table()

      log =
        capture_log(fn ->
          typing
          |> form("#user-form",
            user: %{
              username: "validname",
              email: unique_user_email(),
              password: @typed_password,
              role: "member"
            }
          )
          |> render_change()

          saving |> form("#password-form", user: %{password: @typed_password}) |> render_submit()
        end)

      assert_redirect(typing, ~p"/users/log_in")
      assert_redirect(saving, ~p"/users/log_in")
      assert log =~ "CakeWeb.UserAuth"
      refute_logged(log, @typed_password)
    end

    # A field is text. A request that sends something else in its place (a
    # browser cannot, a hand-written one can) is treated as not having sent
    # the field; it used to reach the template and crash the page there.
    test "a field sent as something other than text is ignored, on a change and on a save",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users/new")

      malformed = %{
        "username" => %{"a" => "b"},
        "password" => @typed_password,
        "role" => %{"a" => "b"}
      }

      {_html, log} =
        with_log(fn ->
          assert render_change(lv, "validate", %{"user" => malformed}) =~ "New login"
          assert render_submit(lv, "save", %{"user" => malformed}) =~ "New login"

          assert render_change(lv, "validate", %{"user" => "password=#{@typed_password}"}) =~
                   "New login"

          assert render_submit(lv, "save", %{"user" => ["password", @typed_password]}) =~
                   "New login"
        end)

      assert has_element?(lv, "#user-form")
      refute_logged(log, @typed_password)
      refute held_by(lv) =~ @typed_password
    end

    test "an event the form does not know is ignored", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users/new")

      assert render_hook(lv, "save", %{}) =~ "New login"

      assert render_hook(lv, "nonsense", %{"user" => %{"password" => @typed_password}}) =~
               "New login"
    end
  end

  describe "editing a login" do
    setup :log_in_admin

    test "changes the username, the email and the role, and asks for no password",
         %{conn: conn} do
      member = login_fixture(:member)
      username = unique_user_username()
      email = unique_user_email()
      {:ok, index, _html} = live(conn, ~p"/admin/users")

      assert {:ok, lv, _html} =
               index
               |> element("#edit-#{member.id}")
               |> render_click()
               |> follow_redirect(conn, ~p"/admin/users/#{member}/edit")

      assert text_of(lv, "h1") == "Edit login"
      assert render(lv) =~ "The username, email and role of #{member.username}."
      refute has_element?(lv, ~s|#user-form input[type="password"]|)

      assert {:ok, index, _html} =
               lv
               |> form("#user-form", user: %{username: username, email: email, role: "admin"})
               |> render_submit()
               |> follow_redirect(conn, ~p"/admin/users")

      assert has_element?(index, "#flash-info", "Login updated")
      assert text_of(index, "#users-#{member.id}") =~ "#{username} #{email} admin"

      assert %User{username: ^username, email: ^email, role: :admin} =
               Accounts.get_user!(member.id)
    end

    # The admin vouches for the address they type, as they do for a login
    # they create, so a changed email stays confirmed.
    test "keeps the login confirmed when its email is changed", %{conn: conn} do
      member = login_fixture(:member)
      email = unique_user_email()
      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{member}/edit")

      assert {:ok, index, _html} =
               lv
               |> form("#user-form", user: %{email: email})
               |> render_submit()
               |> follow_redirect(conn, ~p"/admin/users")

      assert has_element?(index, "#flash-info", "Login updated")
      assert %User{email: ^email, confirmed_at: %DateTime{}} = Accounts.get_user!(member.id)
      assert can_log_in?(member.username, valid_user_password())
    end

    test "refuses an email another login has, as an error on the field, and requires one",
         %{conn: conn, admin: admin} do
      member = login_fixture(:member)
      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{member}/edit")

      assert lv |> form("#user-form", user: %{email: admin.email}) |> render_submit() =~ @taken

      assert lv |> form("#user-form", user: %{email: ""}) |> render_submit() =~
               "can&#39;t be blank"

      assert Accounts.get_user!(member.id).email == member.email
    end

    test "goes back to the login's own page when it was opened from there", %{conn: conn} do
      member = login_fixture(:member)
      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{member}/edit?return_to=show")

      assert {:ok, _show, _html} =
               lv
               |> form("#user-form", user: %{role: "admin"})
               |> render_submit()
               |> follow_redirect(conn, ~p"/admin/users/#{member}")
    end

    # The form sends both fields every time. Only what the admin changed on
    # this form is written, so a form opened a while ago does not put back
    # what someone else has changed since.
    test "writes only the field that was changed on the form, over a change made elsewhere meanwhile",
         %{conn: conn} do
      renamed = login_fixture(:member)
      promoted = login_fixture(:member)
      new_name = unique_user_username()

      {:ok, role_form, _html} = live(conn, ~p"/admin/users/#{renamed}/edit")
      {:ok, name_form, _html} = live(conn, ~p"/admin/users/#{promoted}/edit")

      {:ok, _} = Accounts.update_user(renamed, %{username: new_name})
      {:ok, _} = Accounts.update_user(promoted, %{role: :admin})

      role_form |> form("#user-form", user: %{role: "admin"}) |> render_submit()
      assert %User{username: ^new_name, role: :admin} = Accounts.get_user!(renamed.id)

      other_name = unique_user_username()
      name_form |> form("#user-form", user: %{username: other_name}) |> render_submit()
      assert %User{username: ^other_name, role: :admin} = Accounts.get_user!(promoted.id)
    end

    # After a refused save the form shows the login as it is now. What the
    # admin then changes is measured against what the form shows, not
    # against the login as it was when the form was first opened.
    test "after a refused save, a field set back to what it was when the form was opened is still a change",
         %{conn: conn, admin: admin} do
      member = login_fixture(:member)
      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{member}/edit")
      {:ok, _promoted} = Accounts.update_user(member, %{role: :admin})

      refused = lv |> form("#user-form", user: %{username: admin.username}) |> render_submit()

      assert refused =~ @taken

      assert refused
             |> Floki.parse_document!()
             |> Floki.attribute("#user_role option[selected]", "value") == ["admin"]

      lv
      |> form("#user-form", user: %{username: member.username, role: "member"})
      |> render_submit()

      assert Accounts.get_user!(member.id).role == :member
    end

    test "says so, and goes back to the list, when the login was deleted meanwhile", %{conn: conn} do
      member = login_fixture(:member)
      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{member}/edit")
      {:ok, _deleted} = Accounts.delete_user(member)

      assert {:ok, index, _html} =
               lv
               |> form("#user-form", user: %{role: "admin"})
               |> render_submit()
               |> follow_redirect(conn, ~p"/admin/users")

      assert has_element?(index, "#flash-error", @gone)
    end

    test "leaves the password alone, even when a request carries one", %{conn: conn} do
      member = login_fixture(:member)
      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{member}/edit")

      # Not the form: the event a hand-written client would send.
      render_submit(lv, "save", %{
        "user" => %{
          "username" => member.username,
          "role" => "member",
          "password" => @typed_password
        }
      })

      assert can_log_in?(member.username, valid_user_password())
      refute can_log_in?(member.username, @typed_password)
    end

    test "refuses a username another login has, as an error on the field", %{
      conn: conn,
      admin: admin
    } do
      member = login_fixture(:member)
      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{member}/edit")

      html =
        lv
        |> form("#user-form", user: %{username: admin.username, role: "member"})
        |> render_submit()

      assert html =~ @taken
      assert Accounts.get_user!(member.id).username == member.username
    end

    test "refuses to demote the last admin, as an error on the role, and changes nothing",
         %{conn: conn, admin: admin} do
      login_fixture(:member)
      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{admin}/edit")

      html =
        lv
        |> form("#user-form", user: %{username: unique_user_username(), role: "member"})
        |> render_submit()

      assert html =~ @last_admin
      assert %User{role: :admin, username: username} = Accounts.get_user!(admin.id)
      assert username == admin.username

      # The page is still there, and still works.
      assert has_element?(lv, "#user-form")
    end

    test "demotes an admin while another remains", %{conn: conn} do
      other = login_fixture(:admin)
      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{other}/edit")

      lv |> form("#user-form", user: %{role: "member"}) |> render_submit()

      assert Accounts.get_user!(other.id).role == :member
    end
  end

  describe "setting a password" do
    setup :log_in_admin

    test "is its own form, with the password and nothing else", %{conn: conn} do
      member = login_fixture(:member)
      {:ok, show, _html} = live(conn, ~p"/admin/users/#{member}")

      assert {:ok, lv, _html} =
               show
               |> element("#set-password")
               |> render_click()
               |> follow_redirect(conn, ~p"/admin/users/#{member}/password")

      assert text_of(lv, "h1") == "Set password"
      assert has_element?(lv, ~s|#password-form input[type="password"][name="user[password]"]|)
      refute has_element?(lv, ~s|#password-form [name="user[username]"]|)
      refute has_element?(lv, ~s|#password-form [name="user[role]"]|)
    end

    test "makes the old password stop working everywhere at once: sessions, tokens and open pages",
         %{conn: conn, admin: admin} do
      member = login_fixture(:member)
      %{token: token, lv: members_page} = open_page_as(member)

      {_encoded, reset_token} =
        UserToken.build_email_token(%{member | email: "member@example.com"}, "reset_password")

      Repo.insert!(reset_token)

      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{member}/password")

      assert {:ok, show, _html} =
               lv
               |> form("#password-form", user: %{password: @typed_password})
               |> render_submit()
               |> follow_redirect(conn, ~p"/admin/users/#{member}")

      assert has_element?(show, "#flash-info", "Password set")
      refute render(show) =~ @typed_password

      refute Accounts.get_user_by_session_token(token)
      assert Repo.all(UserToken.by_user_and_contexts_query(member, :all)) == []
      assert_redirect(members_page, ~p"/users/log_in")

      # After the tokens are checked: logging in makes one.
      refute can_log_in?(member.username, valid_user_password())
      assert can_log_in?(member.username, @typed_password)

      # Nobody else is logged out: the admin who did it carries on.
      assert Repo.all(UserToken.by_user_and_contexts_query(admin, :all)) != []
      assert has_element?(show, "#login")
    end

    test "holds the password to the length rule, renders nothing back, and ends no session",
         %{conn: conn} do
      member = login_fixture(:member)
      %{token: token, lv: members_page} = open_page_as(member)
      short = "2-sh0rt!"

      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{member}/password")

      changed = lv |> form("#password-form", user: %{password: short}) |> render_change()
      assert changed =~ @too_short
      refute changed =~ short

      submitted = lv |> form("#password-form", user: %{password: short}) |> render_submit()
      assert submitted =~ @too_short
      refute submitted =~ short

      assert can_log_in?(member.username, valid_user_password())
      assert Accounts.get_user_by_session_token(token)
      refute_redirected(members_page, ~p"/users/log_in")
    end

    test "changes the password and nothing else, whatever else a request carries", %{conn: conn} do
      member = login_fixture(:member)
      {:ok, lv, _html} = live(conn, ~p"/admin/users/#{member}/password")

      render_submit(lv, "save", %{
        "user" => %{"password" => @typed_password, "role" => "admin", "username" => "renamed"}
      })

      assert %User{role: :member, username: username} = Accounts.get_user!(member.id)
      assert username == member.username
      assert can_log_in?(member.username, @typed_password)
    end
  end

  describe "deleting a login" do
    setup :log_in_admin

    test "asks for confirmation, then removes the login, its sessions and its open pages",
         %{conn: conn} do
      member = login_fixture(:member)
      %{token: token, lv: members_page} = open_page_as(member)
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      assert lv |> element("#delete-#{member.id}") |> render() =~ "data-confirm="

      lv |> element("#delete-#{member.id}") |> render_click()

      refute has_element?(lv, "#users-#{member.id}")
      refute Repo.get(User, member.id)
      refute Accounts.get_user_by_session_token(token)
      assert_redirect(members_page, ~p"/users/log_in")
      refute has_element?(lv, "#users-refusal")
      assert has_element?(lv, "#flash-info", "Login deleted")
    end

    test "does not leave the last deletion's message beside a refusal", %{
      conn: conn,
      admin: admin
    } do
      member = login_fixture(:member)
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      lv |> element("#delete-#{member.id}") |> render_click()
      assert has_element?(lv, "#flash-info", "Login deleted")

      render_click(lv, "delete", %{"id" => admin.id})

      assert has_element?(lv, "#users-refusal")
      refute has_element?(lv, "#flash-info")
    end

    test "deletes another admin while one remains", %{conn: conn} do
      other = login_fixture(:admin)
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      lv |> element("#delete-#{other.id}") |> render_click()

      refute Repo.get(User, other.id)
    end

    test "takes a login that was already deleted off the list, and says so", %{conn: conn} do
      member = login_fixture(:member)
      {:ok, lv, _html} = live(conn, ~p"/admin/users")
      {:ok, _deleted} = Accounts.delete_user(member)

      lv |> element("#delete-#{member.id}") |> render_click()

      refute has_element?(lv, "#users-#{member.id}")
      assert text_of(lv, "#users-refusal [data-part=body]") == @gone
    end

    test "answers a request to delete what is not a login as one for a login that is gone, and ignores one that names nothing",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")
      count = Repo.aggregate(User, :count)

      render_click(lv, "delete", %{})
      refute has_element?(lv, "#users-refusal")

      render_click(lv, "delete", %{"id" => "not-an-id"})
      assert text_of(lv, "#users-refusal [data-part=body]") == @gone

      assert has_element?(lv, "#users")
      assert Repo.aggregate(User, :count) == count
    end

    test "offers an admin no way to delete their own login", %{conn: conn, admin: admin} do
      login_fixture(:admin)
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      assert has_element?(lv, "#users-#{admin.id}")
      refute has_element?(lv, "#delete-#{admin.id}")
    end

    test "refuses an admin's request to delete their own login with a notice, and deletes nothing",
         %{conn: conn, admin: admin} do
      # Another admin exists, so this is not the last-admin rule.
      login_fixture(:admin)
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      # The page has no control for it: the event a hand-written client
      # would send.
      render_click(lv, "delete", %{"id" => admin.id})

      assert text_of(lv, "#users-refusal [data-part=body]") == @own_login
      assert has_element?(lv, "#users-refusal.alert-error")
      assert Repo.get(User, admin.id)
      assert has_element?(lv, "#users-#{admin.id}")
    end

    test "refuses the only admin's request to delete their own login the same way", %{
      conn: conn,
      admin: admin
    } do
      login_fixture(:member)
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      render_click(lv, "delete", %{"id" => admin.id})

      assert text_of(lv, "#users-refusal [data-part=body]") == @own_login
      assert %User{role: :admin} = Repo.get(User, admin.id)
    end
  end

  # Every route of the panel, for a login that exists.
  defp panel_paths(%User{} = user) do
    [
      ~p"/admin/users",
      ~p"/admin/users/new",
      ~p"/admin/users/#{user}",
      ~p"/admin/users/#{user}/edit",
      ~p"/admin/users/#{user}/password"
    ]
  end

  describe "access" do
    test "an admin opens every screen, each with its title", %{conn: conn} do
      admin = login_fixture(:admin)
      conn = log_in_user(conn, admin)

      titles = ["Logins", "New login", admin.username, "Edit login", "Set password"]

      for {path, title} <- Enum.zip(panel_paths(admin), titles) do
        assert {:ok, lv, _html} = live(conn, path)
        assert page_title(lv) == "#{title} · Cake", path
        assert conn |> get(path) |> html_response(200), path
      end
    end

    test "a member is sent to the home page with a not-authorized flash, from every screen",
         %{conn: conn} do
      member = login_fixture(:member)
      conn = log_in_user(conn, member)

      for path <- panel_paths(member) do
        assert {:error, {:redirect, %{to: "/", flash: %{"error" => @not_authorized}}}} =
                 live(conn, path),
               path

        response = get(conn, path)
        assert redirected_to(response) == ~p"/", path
        assert Phoenix.Flash.get(response.assigns.flash, :error) == @not_authorized, path
      end
    end

    test "a visitor who is not logged in is sent to the log-in page, from every screen",
         %{conn: conn} do
      user = login_fixture(:member)

      for path <- panel_paths(user) do
        assert {:error, {:redirect, %{to: "/users/log_in", flash: %{"error" => @must_log_in}}}} =
                 live(conn, path),
               path

        assert conn |> get(path) |> redirected_to() == ~p"/users/log_in", path
      end
    end

    # The guard runs when a page is opened (#373). A page that is already
    # open has to check again when it is asked to do something.
    test "an admin demoted while the list is open can delete nothing from it", %{conn: conn} do
      admin = login_fixture(:admin)
      login_fixture(:admin)
      member = login_fixture(:member)
      {:ok, lv, _html} = conn |> log_in_user(admin) |> live(~p"/admin/users")

      {:ok, _demoted} = Accounts.update_user_role(admin, :member)

      render_click(lv, "delete", %{"id" => member.id})

      assert_redirect(lv, ~p"/")
      assert Repo.get(User, member.id)
    end

    test "an admin deleted or logged out while the list is open is sent to the log-in page, and deletes nothing",
         %{conn: conn} do
      deleted = login_fixture(:admin)
      logged_out = login_fixture(:admin)
      member = login_fixture(:member)

      {:ok, deleted_page, _html} = conn |> log_in_user(deleted) |> live(~p"/admin/users")
      logged_out_conn = log_in_user(conn, logged_out)
      {:ok, logged_out_page, _html} = live(logged_out_conn, ~p"/admin/users")

      # Straight to the context and the token, so nothing tells the pages.
      {:ok, _} = Accounts.delete_user(deleted)
      :ok = Accounts.delete_user_session_token(get_session(logged_out_conn, :user_token))

      for page <- [deleted_page, logged_out_page] do
        render_click(page, "delete", %{"id" => member.id})
        assert_redirect(page, ~p"/users/log_in")
      end

      assert Repo.get(User, member.id)
    end

    test "an admin demoted while a form is open can save nothing from it", %{conn: conn} do
      admin = login_fixture(:admin)
      login_fixture(:admin)
      member = login_fixture(:member)
      conn = log_in_user(conn, admin)

      {:ok, new, _html} = live(conn, ~p"/admin/users/new")
      {:ok, edit, _html} = live(conn, ~p"/admin/users/#{member}/edit")
      {:ok, password, _html} = live(conn, ~p"/admin/users/#{member}/password")

      {:ok, _demoted} = Accounts.update_user_role(admin, :member)

      username = unique_user_username()

      render_submit(new, "save", %{
        "user" => %{
          "username" => username,
          "email" => unique_user_email(),
          "password" => @typed_password,
          "role" => "admin"
        }
      })

      render_submit(edit, "save", %{"user" => %{"role" => "admin"}})
      render_submit(password, "save", %{"user" => %{"password" => @typed_password}})

      for lv <- [new, edit, password], do: assert_redirect(lv, ~p"/")

      refute Repo.get_by(User, username: username)
      assert Accounts.get_user!(member.id).role == :member
      assert can_log_in?(member.username, valid_user_password())
    end
  end
end
