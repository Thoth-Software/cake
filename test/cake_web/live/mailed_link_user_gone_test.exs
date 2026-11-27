defmodule CakeWeb.MailedLinkUserGoneTest do
  @moduledoc """
  The pages that mail a link, when the user is deleted before the link is
  stored (#427).

  Three pages find a user and then mail them a link, which stores a token
  for them: registration (the user it has just stored), the confirmation
  instructions page and the forgotten-password page (the user an email
  matches). An admin can delete the user in between. Each page used to
  crash for it. Now registration says that the account no longer exists
  and keeps the form up, so the visitor can register again; the other two
  answer as they answer any email, since what they say never depends on
  whom the email matches.

  No test can put a deletion between the two calls of one event. So a
  trigger stands in for it: it deletes a token's user as the token is
  stored, before the token's reference to them is checked, and the
  reference then fails as it does for a user deleted meanwhile. The failed
  statement takes the trigger's deletion back with it, so the user row is
  there again afterwards; what each page answers is what this pins.

  The trigger is created inside the test's transaction, which the sandbox
  rolls back. Creating it locks `users_tokens` against every other test's
  writes until then, so this module is not `async`.

  The settings page mails a link too, for a changed email. Its user is the
  one logged in, who can be deleted before the form is submitted, so its
  test needs no trigger: it is in `CakeWeb.UserSettingsLiveTest`.
  """

  use CakeWeb.ConnCase

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import Cake.AccountsFixtures

  alias Cake.Accounts.UserToken
  alias Cake.Repo

  defp delete_users_as_their_tokens_are_stored do
    Repo.query!("""
    CREATE FUNCTION delete_the_user_of_a_token() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      DELETE FROM users WHERE id = NEW.user_id;
      RETURN NEW;
    END
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER user_deleted_meanwhile BEFORE INSERT ON users_tokens
    FOR EACH ROW EXECUTE FUNCTION delete_the_user_of_a_token()
    """)
  end

  test "registration says that the account no longer exists, keeps the form up, and mails nothing",
       %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/users/register")
    delete_users_as_their_tokens_are_stored()

    lv
    |> form("#registration_form",
      user: %{
        username: unique_user_username(),
        email: unique_user_email(),
        password: valid_user_password()
      }
    )
    |> render_submit()

    # Not sent on to the log-in page, as a registration is: the visitor is
    # still on the form.
    refute_redirected(lv, ~p"/users/log_in")
    assert has_element?(lv, "#flash-error", "That account no longer exists.")
    assert has_element?(lv, "#registration_form")

    assert_no_email_sent()
    assert Repo.all(UserToken) == []
  end

  test "the confirmation instructions page answers as it answers any email, and mails nothing",
       %{conn: conn} do
    user = unconfirmed_user_fixture()
    {:ok, lv, _html} = live(conn, ~p"/users/confirm")
    delete_users_as_their_tokens_are_stored()

    lv |> form("#resend_confirmation_form", user: %{email: user.email}) |> render_submit()

    assert assert_redirect(lv, ~p"/") == %{
             "info" =>
               "If your email is in our system and it has not been confirmed yet, you will receive an email with instructions shortly."
           }

    assert_no_email_sent()
    assert Repo.all(UserToken) == []
  end

  test "the forgotten-password page answers as it answers any email, and mails nothing", %{
    conn: conn
  } do
    user = user_fixture()
    {:ok, lv, _html} = live(conn, ~p"/users/reset_password")
    delete_users_as_their_tokens_are_stored()

    lv |> form("#reset_password_form", user: %{email: user.email}) |> render_submit()

    assert assert_redirect(lv, ~p"/") == %{
             "info" =>
               "If your email is in our system, you will receive instructions to reset your password shortly."
           }

    assert_no_email_sent()
    assert Repo.all(UserToken) == []
  end
end
