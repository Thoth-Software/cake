defmodule Cake.Repo do
  @moduledoc """
  The application's Ecto repository, on Postgres. It is the one repo in
  `ecto_repos`, and Oban is configured to keep its jobs in it.
  """

  use Ecto.Repo,
    otp_app: :cake,
    adapter: Ecto.Adapters.Postgres
end
