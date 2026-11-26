defmodule CakeWeb.UserRegistrationLiveGoneTest do
  @moduledoc """
  Registering while the new account is deleted (#427).

  `CakeWeb.UserRegistrationLive` stores the user, then mails the
  confirmation link, which stores a token for them. An admin can delete the
  account in between. The page then says so and stays up, with the form as
  it was, so the visitor can register again: it used to crash, with nothing
  said.

  No test can put a deletion between the two calls of one event. So a
  trigger stands in for it: it deletes a token's user as the token is
  stored, before the token's reference to them is checked, and the
  reference then fails as it does for a user deleted meanwhile. The failed
  statement takes the trigger's deletion back with it, so the user row is
  there again afterwards; what the page answers is what this pins.

  The trigger is created inside the test's transaction, which the sandbox
  rolls back. Creating it locks `users_tokens` against every other test's
  writes until then, so this module is not `async`.
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

  test "says that the account no longer exists, keeps the form up, and mails nothing", %{
    conn: conn
  } do
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
end
