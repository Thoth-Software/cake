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
# gives a dev database someone who can open `/admin`.
#
# The dev stack runs this file on every boot, so it has to be safe to run
# again, and it has to bring an older database up to date: one seeded before
# roles existed has this login as a member, with the username already taken.
# So when the login cannot be created, the one that is there is made an
# admin and confirmed, if it is still the login this file seeded (it has the seeded
# password). A user who took the name with a password of their own is left
# alone.
seeded = %{
  username: "admin",
  email: "admin@fake.com",
  password: "adminpassword@1234",
  role: :admin
}

with {:error, _changeset} <- Cake.Accounts.create_user(seeded),
     %Cake.Accounts.User{} = user <-
       Cake.Accounts.get_user_by_username_and_password(seeded.username, seeded.password),
     {:ok, admin} <- Cake.Accounts.update_user_role(user, :admin) do
  # Log-in waits on confirmation, and a login seeded before that rule (or
  # registered by hand) is not confirmed.
  Cake.Accounts.set_user_confirmed(:operator, admin, true)
end
