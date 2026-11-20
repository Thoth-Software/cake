# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Cake.Repo.insert!(%Cake.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

# The dev login, and an admin: the migrations carry no data, so this is what
# gives a dev database someone who can open `/admin`. The result is ignored
# on purpose: the dev stack runs this file on every boot, and from the second
# boot on the username is taken.
Cake.Accounts.create_user(%{
  username: "admin",
  email: "admin@fake.com",
  password: "adminpassword@1234",
  role: :admin
})
