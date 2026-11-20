defmodule CakeWeb.Admin.UserLiveTest do
  @moduledoc """
  The admin panel for logins (#376): the list at `/admin/users`, the form
  that creates a login and the one that changes it, the separate action that
  sets a password, and deletion.

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

  # A password no fixture uses and no page has a reason to contain, so
  # finding it anywhere means it was put there.
  @typed_password "correct horse battery staple"

  # A login as the panel makes one: a username, a password and a role, and
  # no email. (`user_fixture/1` and `admin_fixture/1` give theirs an email.)
  defp login_fixture(role, attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        username: unique_user_username(),
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

  defp created_on(%User{inserted_at: inserted_at}), do: Calendar.strftime(inserted_at, "%Y-%m-%d")

  defp can_log_in?(username, password) do
    Accounts.get_user_by_username_and_password(username, password) != nil
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

    test "shows each login's username, role and created date, in username order, in the wide column",
         %{conn: conn, admin: admin} do
      Repo.delete_all(from_other_than(admin))
      zoe = login_fixture(:member, %{username: "zoe"})
      abe = login_fixture(:admin, %{username: "Abe"})

      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      assert text_of(lv, "h1") == "Logins"
      assert has_element?(lv, ~s|#page[data-width="wide"]|)

      assert column_labels(lv) == ["Username", "Role", "Created", "Actions"]
      assert row_ids(lv) == Enum.map([abe, admin, zoe], &"users-#{&1.id}")

      assert text_of(lv, "#users-#{zoe.id}") =~ "zoe member #{created_on(zoe)}"
      assert text_of(lv, "#users-#{abe.id}") =~ "Abe admin #{created_on(abe)}"
    end

    test "never shows a password hash", %{conn: conn, admin: admin} do
      {:ok, _lv, html} = live(conn, ~p"/admin/users")

      refute html =~ admin.hashed_password
      refute html =~ "$2b$"
    end

    test "has an email column only when a login has an email", %{conn: conn, admin: admin} do
      Repo.delete_all(from_other_than(admin))
      {:ok, lv, _html} = live(conn, ~p"/admin/users")
      refute "Email" in column_labels(lv)

      with_email = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      assert column_labels(lv) == ["Username", "Email", "Role", "Created", "Actions"]
      assert text_of(lv, "#users-#{with_email.id}") =~ with_email.email
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

    test "shows the username, role and created date, and leads to the form and to setting a password",
         %{conn: conn} do
      member = login_fixture(:member)
      {:ok, lv, html} = live(conn, ~p"/admin/users/#{member}")

      assert text_of(lv, "h1") == member.username
      assert page_title(lv) =~ member.username

      assert text_of(lv, "#login") =~
               "#{member.username} Role member Created #{created_on(member)}"

      refute html =~ member.hashed_password

      assert has_element?(
               lv,
               ~s|a#edit-login[href="/admin/users/#{member.id}/edit?return_to=show"]|
             )

      assert has_element?(lv, ~s|a#set-password[href="/admin/users/#{member.id}/password"]|)
    end
  end

  describe "creating a login" do
    setup :log_in_admin

    test "takes a username, a password and a role, and the login works at once", %{conn: conn} do
      username = unique_user_username()
      {:ok, lv, _html} = live(conn, ~p"/admin/users/new")

      # The redirect is to the bare list: nothing typed is carried in a URL.
      assert {:ok, index, _html} =
               lv
               |> form("#user-form",
                 user: %{username: username, password: @typed_password, role: "member"}
               )
               |> render_submit()
               |> follow_redirect(conn, ~p"/admin/users")

      assert %User{role: :member} = user = Repo.get_by!(User, username: username)
      assert can_log_in?(username, @typed_password)

      assert has_element?(index, "#flash-info", "Login created")
      assert text_of(index, "#users-#{user.id}") =~ "#{username} member"
      refute render(index) =~ @typed_password
    end

    test "makes an admin when asked to", %{conn: conn} do
      username = unique_user_username()
      {:ok, lv, _html} = live(conn, ~p"/admin/users/new")

      lv
      |> form("#user-form", user: %{username: username, password: @typed_password, role: "admin"})
      |> render_submit()

      assert %User{role: :admin} = Repo.get_by!(User, username: username)
    end

    test "holds the password to the length rule, and never renders what was typed back",
         %{conn: conn} do
      username = unique_user_username()
      short = "2short-#{System.unique_integer([:positive])}"
      {:ok, lv, _html} = live(conn, ~p"/admin/users/new")

      changed =
        lv
        |> form("#user-form", user: %{username: username, password: short, role: "member"})
        |> render_change()

      assert changed =~ @too_short
      refute changed =~ short

      submitted =
        lv
        |> form("#user-form", user: %{username: username, password: short, role: "member"})
        |> render_submit()

      assert submitted =~ @too_short
      refute submitted =~ short
      refute Repo.get_by(User, username: username)

      # A valid password is not rendered back either, when something else
      # keeps the form on the page.
      rejected =
        lv
        |> form("#user-form", user: %{username: "x", password: @typed_password, role: "member"})
        |> render_submit()

      refute rejected =~ @typed_password
    end

    test "refuses a username that is taken, whatever its letter case, as an error on the field",
         %{conn: conn, admin: admin} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users/new")

      html =
        lv
        |> form("#user-form",
          user: %{
            username: String.upcase(admin.username),
            password: @typed_password,
            role: "member"
          }
        )
        |> render_submit()

      assert html =~ @taken
      assert Repo.aggregate(User, :count) == 1
    end

    test "logs neither the password typed nor the one submitted", %{conn: conn} do
      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)

      username = unique_user_username()
      {:ok, lv, _html} = live(conn, ~p"/admin/users/new")
      attrs = %{username: username, password: @typed_password, role: "member"}

      log =
        capture_log(fn ->
          lv |> form("#user-form", user: attrs) |> render_change()
          lv |> form("#user-form", user: attrs) |> render_submit()
        end)

      # The submission was logged, with the username in it and the password
      # filtered out of it.
      assert Repo.get_by(User, username: username)
      assert log =~ username
      assert log =~ "[FILTERED]"
      refute log =~ @typed_password
    end
  end

  describe "editing a login" do
    setup :log_in_admin

    test "changes the username and the role, and asks for no password", %{conn: conn} do
      member = login_fixture(:member)
      username = unique_user_username()
      {:ok, index, _html} = live(conn, ~p"/admin/users")

      assert {:ok, lv, _html} =
               index
               |> element("#edit-#{member.id}")
               |> render_click()
               |> follow_redirect(conn, ~p"/admin/users/#{member}/edit")

      assert text_of(lv, "h1") == "Edit login"
      refute has_element?(lv, ~s|#user-form input[type="password"]|)

      assert {:ok, index, _html} =
               lv
               |> form("#user-form", user: %{username: username, role: "admin"})
               |> render_submit()
               |> follow_redirect(conn, ~p"/admin/users")

      assert has_element?(index, "#flash-info", "Login updated")
      assert text_of(index, "#users-#{member.id}") =~ "#{username} admin"
      assert %User{username: ^username, role: :admin} = Accounts.get_user!(member.id)
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

      refute can_log_in?(member.username, valid_user_password())
      assert can_log_in?(member.username, @typed_password)

      refute Accounts.get_user_by_session_token(token)
      assert Repo.all(UserToken.by_user_and_contexts_query(member, :all)) == []
      assert_redirect(members_page, ~p"/users/log_in")

      # Nobody else is logged out: the admin who did it carries on.
      assert Repo.all(UserToken.by_user_and_contexts_query(admin, :all)) != []
      assert has_element?(show, "#login")
    end

    test "holds the password to the length rule, renders nothing back, and ends no session",
         %{conn: conn} do
      member = login_fixture(:member)
      %{token: token, lv: members_page} = open_page_as(member)
      short = "2short-#{System.unique_integer([:positive])}"

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
    end

    test "deletes another admin while one remains", %{conn: conn} do
      other = login_fixture(:admin)
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      lv |> element("#delete-#{other.id}") |> render_click()

      refute Repo.get(User, other.id)
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

      assert has_element?(lv, "#users-refusal.alert-error")
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
        "user" => %{"username" => username, "password" => @typed_password, "role" => "admin"}
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
