defmodule Cake.SeedsTest do
  @moduledoc """
  The dev seed, `priv/repo/seeds.exs` (#372).

  The script discards what `Cake.Accounts.register_user/1` returns, so a seed
  that `register_user/1` refuses fails without a word: the dev database has no
  login and nothing says why. This runs the script and looks at what it left.
  """

  use Cake.DataCase

  alias Cake.Accounts.User

  test "the seed leaves one user, and that user has a username" do
    Code.eval_file(Application.app_dir(:cake, "priv/repo/seeds.exs"))

    assert [%User{} = user] = Repo.all(User)
    assert String.length(user.username) in 3..32
  end
end
