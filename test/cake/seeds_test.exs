defmodule Cake.SeedsTest do
  @moduledoc """
  The dev seed, `priv/repo/seeds.exs` (#372, #373).

  The migrations do not carry data: a database that has users is reset, not
  migrated. So the seed is what gives a dev database its login, and it has to
  be current: one user, with a username, and an admin, or nobody in dev can
  open `/admin`.

  The script discards what the context returns, so a seed the context
  refuses fails without a word: the dev database has no login and nothing
  says why. This runs the script and looks at what it left. The dev stack
  runs it on every boot, so it also has to be safe to run again.
  """

  use Cake.DataCase

  alias Cake.Accounts
  alias Cake.Accounts.User

  # The dev login the seed creates, as `CakeWeb.AdminJourneyTest` also has it.
  @seeded_username "admin"
  @seeded_password "adminpassword@1234"

  defp run_seed, do: Code.eval_file(Application.app_dir(:cake, "priv/repo/seeds.exs"))

  test "the seed leaves one user, with a username, who is an admin" do
    run_seed()

    assert [%User{} = user] = Repo.all(User)
    assert String.length(user.username) in 3..32
    assert user.role == :admin
  end

  test "running the seed again raises nothing and leaves the same one admin" do
    run_seed()
    assert [%User{} = first] = Repo.all(User)

    run_seed()
    assert [%User{} = second] = Repo.all(User)

    assert second.id == first.id
    assert second.role == :admin
  end

  # A dev database from before roles existed: migrating it makes its seeded
  # login a member, because that is the column's default, and the username is
  # taken, so the seed cannot create it again. The seed has to bring the
  # login it owns up to date, or that database has nobody who can open
  # `/admin` (found in review on #387).
  test "the seed makes a dev login from before roles an admin" do
    {:ok, member} =
      Accounts.register_user(%{username: @seeded_username, password: @seeded_password})

    assert member.role == :member

    run_seed()

    assert [%User{} = user] = Repo.all(User)
    assert user.id == member.id
    assert user.role == :admin
  end

  # It promotes the login it seeded, recognised by the seeded password, and
  # not whoever else took the name.
  test "the seed leaves alone a user who has the seed's username and another password" do
    {:ok, other} =
      Accounts.register_user(%{username: @seeded_username, password: "a password of their own"})

    run_seed()

    assert [%User{} = user] = Repo.all(User)
    assert user.id == other.id
    assert user.role == :member
  end
end
