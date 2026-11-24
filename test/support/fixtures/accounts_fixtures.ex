defmodule Cake.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Cake.Accounts` context.
  """

  @spec unique_user_email() :: String.t()
  def unique_user_email, do: "user#{System.unique_integer()}@example.com"

  # Never a substring of `unique_user_email/0` (another prefix, another
  # integer), so a page that shows the email cannot pass for one that shows
  # the username.
  @spec unique_user_username() :: String.t()
  def unique_user_username, do: "member#{System.unique_integer([:positive])}"

  @spec valid_user_password() :: String.t()
  def valid_user_password, do: "hello world!"

  @spec valid_user_attributes(map()) :: map()
  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      username: unique_user_username(),
      email: unique_user_email(),
      password: valid_user_password()
    })
  end

  # A user who can log in: registered, then confirmed, as following the
  # mailed link does. Log-in waits on confirmation, so this is the user most
  # tests want; `unconfirmed_user_fixture/1` is the one registration leaves.
  @spec user_fixture(map()) :: Cake.Accounts.User.t()
  def user_fixture(attrs \\ %{}) do
    attrs
    |> unconfirmed_user_fixture()
    |> Cake.Accounts.User.confirm_changeset()
    |> Cake.Repo.update!()
  end

  # A user as `Cake.Accounts.register_user/1` leaves them: not yet confirmed.
  @spec unconfirmed_user_fixture(map()) :: Cake.Accounts.User.t()
  def unconfirmed_user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Cake.Accounts.register_user()

    user
  end

  # An admin, made the way the first admin is made: `Cake.Accounts.create_user/1`
  # with a role. `user_fixture/1` goes through registration, which never sets
  # one. A created user is confirmed from the start.
  @spec admin_fixture(map()) :: Cake.Accounts.User.t()
  def admin_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Map.put(:role, :admin)
      |> Cake.Accounts.create_user()

    user
  end

  # An admin who cannot log in: registered and not yet confirmed, then
  # promoted, which is how the panel makes one (a promotion confirms
  # nothing). They are an admin by role, and no help to anyone locked out.
  #
  # The promotion takes the advisory lock that every change under the
  # last-admin rule takes, and the sandbox keeps a test's transaction open
  # until the test ends. So a test that calls this holds that lock until it
  # ends, as does any test that makes such a change and is not refused. In
  # an `async: true` module, give such a test usernames and emails of its
  # own (the defaults are), or it can wait on another test's uncommitted
  # name while that test waits on the lock.
  @spec unconfirmed_admin_fixture(map()) :: Cake.Accounts.User.t()
  def unconfirmed_admin_fixture(attrs \\ %{}) do
    {:ok, admin} =
      attrs
      |> unconfirmed_user_fixture()
      |> Cake.Accounts.update_user_role(:admin)

    admin
  end

  @spec extract_user_token((String.t() -> {:ok, Swoosh.Email.t()})) :: String.t()
  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end
end
