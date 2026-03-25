defmodule Cake.Repo do
  use Ecto.Repo,
    otp_app: :cake,
    adapter: Ecto.Adapters.Postgres
end
