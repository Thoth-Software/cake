# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Caque.Repo.insert!(%Caque.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

Caque.Accounts.register_user(%{email: "admin@fake.com", password: "adminpassword@1234"})
