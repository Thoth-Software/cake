defmodule Cake.AccountsTest do
  use Cake.DataCase

  import Cake.AccountsFixtures

  alias Cake.Accounts
  alias Cake.Accounts.User
  alias Cake.Accounts.UserToken

  @username_character_error "can only contain letters a-z, digits, underscores, dots and hyphens"

  # The column itself, under the changesets: the row goes in through
  # `Repo.insert_all/2` on the bare table. What the table holds and refuses
  # for any username or email is in `accounts/user_property_test.exs`.
  describe "the users table" do
    test "requires a username" do
      now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

      row = %{
        id: Ecto.UUID.bingenerate(),
        email: unique_user_email(),
        hashed_password: "x",
        inserted_at: now,
        updated_at: now
      }

      assert_raise Postgrex.Error, ~r/null value in column "username"/, fn ->
        Repo.insert_all("users", [row])
      end
    end

    # The default is the column's own, not only the schema's: a row that
    # names no role (one written before the column existed, or by hand) is
    # a member.
    test "gives a row with no role the member role" do
      now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

      row = %{
        id: Ecto.UUID.bingenerate(),
        username: unique_user_username(),
        hashed_password: "x",
        inserted_at: now,
        updated_at: now
      }

      assert {1, nil} = Repo.insert_all("users", [row])
      assert Repo.all(from(u in "users", select: u.role)) == ["member"]
    end
  end

  describe "get_user_by_email/1" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email("unknown@example.com")
    end

    test "returns the user if the email exists" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user_by_email(user.email)
    end
  end

  describe "get_user_by_email_and_password/2" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email_and_password("unknown@example.com", "hello world!")
    end

    test "does not return the user if the password is not valid" do
      user = user_fixture()
      refute Accounts.get_user_by_email_and_password(user.email, "invalid")
    end

    test "returns the user if the email and password are valid" do
      %{id: id} = user = user_fixture()

      assert %User{id: ^id} =
               Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end
  end

  describe "get_user_by_username_and_password/2" do
    test "does not return the user if the username does not exist" do
      refute Accounts.get_user_by_username_and_password("nobody.by-that_name", "hello world!")
    end

    test "does not return the user if the password is not valid" do
      user = user_fixture()
      refute Accounts.get_user_by_username_and_password(user.username, "invalid")
    end

    test "returns the user if the username and password are valid" do
      %{id: id} = user = user_fixture()

      assert %User{id: ^id} =
               Accounts.get_user_by_username_and_password(user.username, valid_user_password())
    end

    test "returns a user who has no email" do
      %{id: id} = user = user_fixture(email: nil)

      assert %User{id: ^id, email: nil} =
               Accounts.get_user_by_username_and_password(user.username, valid_user_password())
    end

    test "does not take the user's email in place of the username" do
      user = user_fixture()
      refute Accounts.get_user_by_username_and_password(user.email, valid_user_password())
    end
  end

  describe "get_user!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!("00000000-0000-0000-0000-000000000000")
      end
    end

    test "returns the user with the given id" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user!(user.id)
    end
  end

  describe "register_user/1" do
    test "requires username and password to be set, and no email" do
      {:error, changeset} = Accounts.register_user(%{})
      errors = errors_on(changeset)

      assert %{password: ["can't be blank"], username: ["can't be blank"]} = errors
      refute Map.has_key?(errors, :email)
    end

    test "validates the username when given" do
      {:error, too_short} = Accounts.register_user(%{username: "ab"})
      assert errors_on(too_short).username == ["should be at least 3 character(s)"]

      {:error, too_long} = Accounts.register_user(%{username: String.duplicate("a", 33)})
      assert errors_on(too_long).username == ["should be at most 32 character(s)"]

      {:error, bad_character} = Accounts.register_user(%{username: "not valid"})

      assert errors_on(bad_character).username == [@username_character_error]
    end

    # Known hazards for a character-set rule: an email, a `$` anchor (which a
    # trailing newline passes), the non-ASCII characters that case-fold to
    # ASCII letters (the Kelvin sign, the long s), and a name of nothing but
    # whitespace, which `cast/4` takes for blank by default (found by the
    # property test). The general case, and uniqueness whatever the letter
    # case, are properties in `accounts/user_property_test.exs`.
    test "refuses a username with a character outside the set" do
      for username <- [
            "someone@example.com",
            "member\n",
            " member",
            "\u212Aelvin",
            "mi\u017Fter",
            "\n",
            "   "
          ] do
        {:error, changeset} = Accounts.register_user(valid_user_attributes(username: username))

        assert @username_character_error in errors_on(changeset).username
      end
    end

    # #340: a NUL byte passes the email validation today, because the changeset
    # validates first and strips NUL bytes afterwards. A username must not
    # repeat that: the NUL byte is an error, not something to strip and accept.
    test "refuses a username with a NUL byte, and inserts nothing" do
      for username <- ["mem\0ber", "\0member", "member\0"] do
        {:error, changeset} = Accounts.register_user(valid_user_attributes(username: username))

        assert @username_character_error in errors_on(changeset).username
      end

      assert Repo.all(User) == []
    end

    test "registers a user with a username and no email" do
      username = unique_user_username()

      {:ok, user} =
        Accounts.register_user(%{username: username, password: valid_user_password()})

      assert user.username == username
      assert is_nil(user.email)

      stored = Repo.get!(User, user.id)
      assert stored.username == username
      assert is_nil(stored.email)
    end

    test "registers more than one user with no email" do
      {:ok, first} = Accounts.register_user(valid_user_attributes(email: nil))
      {:ok, second} = Accounts.register_user(valid_user_attributes(email: nil))

      assert is_nil(first.email)
      assert is_nil(second.email)
    end

    test "registers a member" do
      {:ok, user} = Accounts.register_user(valid_user_attributes())
      assert user.role == :member
      assert Repo.get!(User, user.id).role == :member
    end

    # Registration is the public page: whatever a visitor posts, they do not
    # choose their role.
    test "ignores a role in the attributes, as an atom key or a string key" do
      {:ok, by_atom} = Accounts.register_user(valid_user_attributes(role: :admin))
      assert Repo.get!(User, by_atom.id).role == :member

      attrs = Map.new(valid_user_attributes(), fn {key, value} -> {to_string(key), value} end)
      {:ok, by_string} = Accounts.register_user(Map.put(attrs, "role", "admin"))
      assert Repo.get!(User, by_string.id).role == :member
    end

    test "validates email and password when given" do
      {:error, changeset} = Accounts.register_user(%{email: "not valid", password: "not valid"})

      assert %{
               email: ["must have the @ sign and no spaces"],
               password: ["should be at least 12 character(s)"]
             } = errors_on(changeset)
    end

    test "validates maximum values for email and password for security" do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Accounts.register_user(%{email: too_long, password: too_long})
      assert "should be at most 160 character(s)" in errors_on(changeset).email
      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "validates email uniqueness" do
      %{email: email} = user_fixture()
      {:error, changeset} = Accounts.register_user(%{email: email})
      assert "has already been taken" in errors_on(changeset).email

      # Now try with the upper cased email too, to check that email case is ignored.
      {:error, upcased_changeset} = Accounts.register_user(%{email: String.upcase(email)})
      assert "has already been taken" in errors_on(upcased_changeset).email
    end

    test "registers users with a hashed password" do
      email = unique_user_email()
      username = unique_user_username()

      {:ok, user} =
        Accounts.register_user(valid_user_attributes(email: email, username: username))

      assert user.email == email
      assert user.username == username
      assert user.hashed_password =~ ~r/^\$2[aby]\$/
      assert is_nil(user.confirmed_at)
      assert is_nil(user.password)
    end
  end

  describe "create_user/1" do
    test "creates an admin who can log in, without confirming anything" do
      username = unique_user_username()

      {:ok, user} =
        Accounts.create_user(%{username: username, password: valid_user_password(), role: :admin})

      assert user.role == :admin
      assert user.username == username
      assert is_nil(user.email)
      assert is_nil(user.confirmed_at)
      assert is_nil(user.password)
      assert user.hashed_password =~ ~r/^\$2[aby]\$/

      found = Accounts.get_user_by_username_and_password(username, valid_user_password())
      assert found.id == user.id
      assert found.role == :admin
    end

    test "creates a member when the role says so" do
      {:ok, user} = Accounts.create_user(valid_user_attributes(role: :member))
      assert Repo.get!(User, user.id).role == :member
    end

    # Unlike registration, which always makes a member, the caller here has
    # to say which role it means: none given, nil and blank are all refused.
    test "requires a role, and inserts nothing without one" do
      attrs = %{username: unique_user_username(), password: valid_user_password()}

      for without_role <- [attrs, Map.put(attrs, :role, nil), Map.put(attrs, :role, "")] do
        {:error, changeset} = Accounts.create_user(without_role)
        assert errors_on(changeset).role == ["can't be blank"]
      end

      assert Repo.all(User) == []
    end

    test "takes the role as a string, as a form or a shell sends it" do
      {:ok, user} =
        Accounts.create_user(%{
          "username" => unique_user_username(),
          "password" => valid_user_password(),
          "role" => "admin"
        })

      assert Repo.get!(User, user.id).role == :admin
    end

    test "requires a username and a password" do
      {:error, changeset} = Accounts.create_user(%{role: :admin})
      errors = errors_on(changeset)

      assert %{username: ["can't be blank"], password: ["can't be blank"]} = errors
      refute Map.has_key?(errors, :role)
    end

    test "holds the username and the password to the rules registration holds them to" do
      {:error, changeset} =
        Accounts.create_user(%{username: "not valid", password: "too short", role: :admin})

      assert %{
               username: [@username_character_error],
               password: ["should be at least 12 character(s)"]
             } = errors_on(changeset)
    end

    test "refuses a taken username, whatever its letter case" do
      username = "Taken.Admin-#{System.unique_integer([:positive])}"
      admin_fixture(username: username)

      {:error, changeset} =
        Accounts.create_user(
          valid_user_attributes(username: String.upcase(username), role: :admin)
        )

      assert "has already been taken" in errors_on(changeset).username
    end

    test "refuses a role that is neither member nor admin, and inserts nothing" do
      {:error, changeset} = Accounts.create_user(valid_user_attributes(role: :owner))

      assert errors_on(changeset).role == ["is invalid"]
      assert Repo.all(User) == []
    end
  end

  describe "update_user_role/2" do
    test "promotes a member" do
      member = user_fixture()

      assert {:ok, promoted} = Accounts.update_user_role(member, :admin)
      assert promoted.id == member.id
      assert promoted.role == :admin
      assert Repo.get!(User, member.id).role == :admin
    end

    test "demotes an admin while another admin remains" do
      admin = admin_fixture()
      other = admin_fixture()

      assert {:ok, demoted} = Accounts.update_user_role(admin, :member)
      assert demoted.role == :member
      assert Repo.get!(User, admin.id).role == :member
      assert Repo.get!(User, other.id).role == :admin
    end

    test "refuses to demote the last admin, and changes nothing" do
      admin = admin_fixture()
      user_fixture()

      assert Accounts.update_user_role(admin, :member) == {:error, :last_admin}
      assert Repo.get!(User, admin.id).role == :admin
    end

    test "leaves the last admin an admin when asked to make them one again" do
      admin = admin_fixture()

      assert {:ok, same} = Accounts.update_user_role(admin, :admin)
      assert same.role == :admin
    end

    # The struct says member; the database says this is the last admin.
    test "goes by the role in the database, not the role on the struct it is given" do
      admin = admin_fixture()
      stale = %{admin | role: :member}

      assert Accounts.update_user_role(stale, :member) == {:error, :last_admin}
      assert Repo.get!(User, admin.id).role == :admin
    end

    test "refuses a role that is neither member nor admin, and changes nothing" do
      member = user_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} = Accounts.update_user_role(member, :owner)
      assert errors_on(changeset).role == ["is invalid"]
      assert Repo.get!(User, member.id).role == :member
    end
  end

  describe "delete_user/1" do
    test "deletes a member" do
      member = user_fixture()

      assert {:ok, deleted} = Accounts.delete_user(member)
      assert deleted.id == member.id
      refute Repo.get(User, member.id)
    end

    test "deletes an admin while another admin remains" do
      admin = admin_fixture()
      other = admin_fixture()

      assert {:ok, _deleted} = Accounts.delete_user(admin)
      refute Repo.get(User, admin.id)
      assert Repo.get!(User, other.id).role == :admin
    end

    test "refuses to delete the last admin, and deletes nothing" do
      admin = admin_fixture()
      user_fixture()

      assert Accounts.delete_user(admin) == {:error, :last_admin}
      assert Repo.get!(User, admin.id).role == :admin
    end

    test "goes by the role in the database, not the role on the struct it is given" do
      admin = admin_fixture()
      stale = %{admin | role: :member}

      assert Accounts.delete_user(stale) == {:error, :last_admin}
      assert Repo.get(User, admin.id)
    end

    test "ends the deleted user's sessions" do
      member = user_fixture()
      token = Accounts.generate_user_session_token(member)
      assert Accounts.get_user_by_session_token(token)

      assert {:ok, _deleted} = Accounts.delete_user(member)
      refute Accounts.get_user_by_session_token(token)
      refute Repo.get_by(UserToken, user_id: member.id)
    end
  end

  describe "change_user_registration/2" do
    test "returns a changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_registration(%User{})
      assert Enum.sort(changeset.required) == [:password, :username]
    end

    test "allows fields to be set" do
      username = unique_user_username()
      email = unique_user_email()
      password = valid_user_password()

      changeset =
        Accounts.change_user_registration(
          %User{},
          valid_user_attributes(username: username, email: email, password: password)
        )

      assert changeset.valid?
      assert get_change(changeset, :username) == username
      assert get_change(changeset, :email) == email
      assert get_change(changeset, :password) == password
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "change_user_email/2" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_email(%User{})
      assert changeset.required == [:email]
    end
  end

  describe "apply_user_email/3" do
    setup do
      %{user: user_fixture()}
    end

    test "requires email to change", %{user: user} do
      {:error, changeset} = Accounts.apply_user_email(user, valid_user_password(), %{})
      assert %{email: ["did not change"]} = errors_on(changeset)
    end

    test "validates email", %{user: user} do
      {:error, changeset} =
        Accounts.apply_user_email(user, valid_user_password(), %{email: "not valid"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "validates maximum value for email for security", %{user: user} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.apply_user_email(user, valid_user_password(), %{email: too_long})

      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "validates email uniqueness", %{user: user} do
      %{email: email} = user_fixture()
      password = valid_user_password()

      {:error, changeset} = Accounts.apply_user_email(user, password, %{email: email})

      assert "has already been taken" in errors_on(changeset).email
    end

    test "validates current password", %{user: user} do
      {:error, changeset} =
        Accounts.apply_user_email(user, "invalid", %{email: unique_user_email()})

      assert %{current_password: ["is not valid"]} = errors_on(changeset)
    end

    test "applies the email without persisting it", %{user: user} do
      email = unique_user_email()
      {:ok, user} = Accounts.apply_user_email(user, valid_user_password(), %{email: email})
      assert user.email == email
      assert Accounts.get_user!(user.id).email != email
    end
  end

  describe "deliver_user_update_email_instructions/3" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      encoded_token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(user, "current@example.com", url)
        end)

      {:ok, token} = Base.url_decode64(encoded_token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "change:current@example.com"
    end
  end

  describe "update_user_email/2" do
    setup do
      user = user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{user: user, token: token, email: email}
    end

    test "updates the email with a valid token", %{user: user, token: token, email: email} do
      assert Accounts.update_user_email(user, token) == :ok
      changed_user = Repo.get!(User, user.id)
      assert changed_user.email != user.email
      assert changed_user.email == email
      assert changed_user.confirmed_at
      assert changed_user.confirmed_at != user.confirmed_at
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email with invalid token", %{user: user} do
      assert Accounts.update_user_email(user, "oops") == :error
      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if user email changed", %{user: user, token: token} do
      assert Accounts.update_user_email(%{user | email: "current@example.com"}, token) == :error
      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      assert Accounts.update_user_email(user, token) == :error
      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "change_user_password/2" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_password(%User{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_user_password(%User{}, %{
          "password" => "new valid password"
        })

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_user_password/3" do
    setup do
      %{user: user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_password(user, valid_user_password(), %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{user: user} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.update_user_password(user, valid_user_password(), %{password: too_long})

      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "validates current password", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_password(user, "invalid", %{password: valid_user_password()})

      assert %{current_password: ["is not valid"]} = errors_on(changeset)
    end

    test "updates the password", %{user: user} do
      {:ok, user} =
        Accounts.update_user_password(user, valid_user_password(), %{
          password: "new valid password"
        })

      assert is_nil(user.password)
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Accounts.generate_user_session_token(user)

      {:ok, _} =
        Accounts.update_user_password(user, valid_user_password(), %{
          password: "new valid password"
        })

      refute Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "generate_user_session_token/1" do
    setup do
      %{user: user_fixture()}
    end

    test "generates a token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.context == "session"

      # Creating the same token for another user should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%UserToken{
          token: user_token.token,
          user_id: user_fixture().id,
          context: "session"
        })
      end
    end
  end

  describe "get_user_by_session_token/1" do
    setup do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      %{user: user, token: token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert session_user = Accounts.get_user_by_session_token(token)
      assert session_user.id == user.id
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_session_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "delete_user_session_token/1" do
    test "deletes the token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert Accounts.delete_user_session_token(token) == :ok
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "deliver_user_confirmation_instructions/2" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      encoded_token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      {:ok, token} = Base.url_decode64(encoded_token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "confirm"
    end
  end

  describe "confirm_user/1" do
    setup do
      user = user_fixture()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_confirmation_instructions(user, url)
        end)

      %{user: user, token: token}
    end

    test "confirms the email with a valid token", %{user: user, token: token} do
      assert {:ok, confirmed_user} = Accounts.confirm_user(token)
      assert confirmed_user.confirmed_at
      assert confirmed_user.confirmed_at != user.confirmed_at
      assert Repo.get!(User, user.id).confirmed_at
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not confirm with invalid token", %{user: user} do
      assert Accounts.confirm_user("oops") == :error
      refute Repo.get!(User, user.id).confirmed_at
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not confirm email if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      assert Accounts.confirm_user(token) == :error
      refute Repo.get!(User, user.id).confirmed_at
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "deliver_user_reset_password_instructions/2" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      encoded_token =
        extract_user_token(fn url ->
          Accounts.deliver_user_reset_password_instructions(user, url)
        end)

      {:ok, token} = Base.url_decode64(encoded_token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "reset_password"
    end
  end

  describe "get_user_by_reset_password_token/1" do
    setup do
      user = user_fixture()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_reset_password_instructions(user, url)
        end)

      %{user: user, token: token}
    end

    test "returns the user with valid token", %{user: %{id: id}, token: token} do
      assert %User{id: ^id} = Accounts.get_user_by_reset_password_token(token)
      assert Repo.get_by(UserToken, user_id: id)
    end

    test "does not return the user with invalid token", %{user: user} do
      refute Accounts.get_user_by_reset_password_token("oops")
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not return the user if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      refute Accounts.get_user_by_reset_password_token(token)
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "reset_user_password/2" do
    setup do
      %{user: user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Accounts.reset_user_password(user, %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{user: user} do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Accounts.reset_user_password(user, %{password: too_long})
      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{user: user} do
      {:ok, updated_user} = Accounts.reset_user_password(user, %{password: "new valid password"})
      assert is_nil(updated_user.password)
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Accounts.generate_user_session_token(user)
      {:ok, _} = Accounts.reset_user_password(user, %{password: "new valid password"})
      refute Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "inspect/2 for the User module" do
    test "does not include password" do
      refute inspect(%User{password: "123456"}) =~ "password: \"123456\""
    end
  end

  describe "users" do
    alias Cake.Accounts.User

    import Cake.AccountsFixtures

    @invalid_attrs %{username: nil, role: nil}

    test "list_users/0 returns all users" do
      user = user_fixture()
      assert Accounts.list_users() == [user]
    end

    test "get_user!/1 returns the user with given id" do
      user = user_fixture()
      assert Accounts.get_user!(user.id) == user
    end

    test "create_user/1 with valid data creates a user" do
      valid_attrs = %{username: "some username", role: :member}

      assert {:ok, %User{} = user} = Accounts.create_user(valid_attrs)
      assert user.username == "some username"
      assert user.role == :member
    end

    test "create_user/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Accounts.create_user(@invalid_attrs)
    end

    test "update_user/2 with valid data updates the user" do
      user = user_fixture()
      update_attrs = %{username: "some updated username", role: :admin}

      assert {:ok, %User{} = user} = Accounts.update_user(user, update_attrs)
      assert user.username == "some updated username"
      assert user.role == :admin
    end

    test "update_user/2 with invalid data returns error changeset" do
      user = user_fixture()
      assert {:error, %Ecto.Changeset{}} = Accounts.update_user(user, @invalid_attrs)
      assert user == Accounts.get_user!(user.id)
    end

    test "delete_user/1 deletes the user" do
      user = user_fixture()
      assert {:ok, %User{}} = Accounts.delete_user(user)
      assert_raise Ecto.NoResultsError, fn -> Accounts.get_user!(user.id) end
    end

    test "change_user/1 returns a user changeset" do
      user = user_fixture()
      assert %Ecto.Changeset{} = Accounts.change_user(user)
    end
  end
end
