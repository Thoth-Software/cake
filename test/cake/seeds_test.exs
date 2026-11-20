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

  alias Cake.Accounts.User

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
end
