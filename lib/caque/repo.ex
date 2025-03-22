defmodule Caque.Repo do
  use Ecto.Repo,
    otp_app: :caque,
    adapter: Ecto.Adapters.Postgres
end
