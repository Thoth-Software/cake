defmodule Cake.Accounts.UserPropertyTest do
  @moduledoc """
  Property tests for the username rules of `Cake.Accounts.User` (#372).

  A username is 3 to 32 characters from `a-z`, `0-9`, `_`, `.` and `-`.
  Letters are accepted in either case: the name is stored as typed and
  compared case-insensitively. Anything else, a NUL byte included, is a
  validation error.

  Four layers:

    * the shape rules, through `Cake.Accounts.change_user_registration/2`,
      which neither queries the Repo nor hashes a password;
    * registration, through `Cake.Accounts.register_user/1`: uniqueness
      whatever the letter case, and nothing inserted for a refused name;
    * the lookup, `Cake.Accounts.get_user_by_username_and_password/2`;
    * the `users` table itself, through `Repo.insert_all/2`, so no changeset
      stands between the property and the constraints the migration declares.

  Example tests, the named hazards among them, live in
  `test/cake/accounts_test.exs`.
  """

  use Cake.DataCase, async: true
  use ExUnitProperties

  import Cake.AccountsFixtures

  alias Cake.Accounts
  alias Cake.Accounts.User

  @allowed_characters [?a..?z, ?A..?Z, ?0..?9, ?_, ?., ?-]

  @too_short "should be at least 3 character(s)"
  @too_long "should be at most 32 character(s)"
  @bad_character "can only contain letters a-z, digits, underscores, dots and hyphens"

  # Each iteration of a property that goes through the Repo inserts rows.
  @max_db_runs 25

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp valid_username, do: string(@allowed_characters, min_length: 3, max_length: 32)

  defp allowed_character?(<<codepoint::utf8>>) do
    Enum.any?(@allowed_characters, fn
      %Range{} = range -> codepoint in range
      single -> codepoint == single
    end)
  end

  # One character outside the set. The named ones are the hazards: the NUL
  # byte (which `sanitize_text_fields/1` strips, so sanitising before
  # validating would let it through), whitespace (a trailing newline passes a
  # `$` anchor), the characters an email has and a username has not, and the
  # two non-ASCII characters that case-fold to ASCII letters (the Kelvin sign
  # to `k`, the long s to `s`), which a case-insensitive Unicode regex accepts.
  defp forbidden_character do
    one_of([
      constant("\0"),
      member_of(["\n", " ", "\t", "@", "+", "/", "é", "K", "ſ"]),
      filter(string(:utf8, length: 1), &(not allowed_character?(&1)))
    ])
  end

  # Allowed characters around one forbidden character. Either side may be
  # empty, so the forbidden character also comes first, last and alone.
  defp username_with_a_forbidden_character do
    gen all(
          before <- string(@allowed_characters, max_length: 15),
          forbidden <- forbidden_character(),
          rest <- string(@allowed_characters, max_length: 15)
        ) do
      before <> forbidden <> rest
    end
  end

  # The same name with the case of each letter chosen independently; the
  # name itself is one of the outcomes.
  defp case_variant(username) do
    gen all(upcase? <- list_of(boolean(), length: String.length(username))) do
      username
      |> String.graphemes()
      |> Enum.zip(upcase?)
      |> Enum.map_join(fn
        {character, true} -> String.upcase(character)
        {character, false} -> String.downcase(character)
      end)
    end
  end

  # Two usernames: half the time one name in two letter cases, half the time
  # two names generated apart (which seldom collide, and sometimes do).
  defp two_usernames do
    one_of([
      gen all(username <- valid_username(), variant <- case_variant(username)) do
        {username, variant}
      end,
      {valid_username(), valid_username()}
    ])
  end

  defp same_username?(first, second), do: String.downcase(first) == String.downcase(second)

  defp email do
    gen all(local_part <- string(:alphanumeric, min_length: 1, max_length: 12)) do
      local_part <> "@table.example"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # A registration with a username and a password and no email at all.
  defp registration(username) do
    Accounts.change_user_registration(%User{}, %{
      username: username,
      password: valid_user_password()
    })
  end

  defp username_errors(changeset), do: Map.get(errors_on(changeset), :username, [])

  # Every iteration of a Repo-backed property starts from an empty table, so
  # none (and no shrink step) sees a row an earlier one left, pass or fail.
  # It is a delete and not a transaction around the iteration: inside an
  # explicit transaction a refused insert aborts it, and the statements after
  # the refusal would fail for that reason instead of their own.
  defp empty_users_table, do: Repo.delete_all(User)

  # A row for `Repo.insert_all("users", _)`: the columns the table has always
  # required, plus the ones given.
  defp users_row(columns) do
    now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

    Map.merge(
      %{id: Ecto.UUID.bingenerate(), hashed_password: "x", inserted_at: now, updated_at: now},
      columns
    )
  end

  defp insert_row(columns), do: Repo.insert_all("users", [users_row(columns)])

  # ---------------------------------------------------------------------------
  # Shape
  # ---------------------------------------------------------------------------

  property "a username of allowed characters is refused exactly when it is shorter than 3 or longer than 32" do
    check all(username <- string(@allowed_characters, min_length: 1, max_length: 64)) do
      changeset = registration(username)

      case String.length(username) do
        length when length < 3 ->
          assert username_errors(changeset) == [@too_short]

        length when length > 32 ->
          assert username_errors(changeset) == [@too_long]

        _length ->
          assert username_errors(changeset) == []
      end
    end
  end

  property "a well-formed username and a password make a valid registration, with no email, and the username is kept as typed" do
    check all(username <- valid_username()) do
      changeset = registration(username)

      assert changeset.valid?
      assert get_change(changeset, :username) == username
    end
  end

  property "a username with any character outside the set is a validation error, a NUL byte included" do
    check all(username <- username_with_a_forbidden_character()) do
      changeset = registration(username)

      refute changeset.valid?
      assert @bad_character in username_errors(changeset)
    end
  end

  # ---------------------------------------------------------------------------
  # Registration
  # ---------------------------------------------------------------------------

  property "a username that differs from a registered one only in letter case is already taken" do
    check all(
            username <- valid_username(),
            variant <- case_variant(username),
            max_runs: @max_db_runs
          ) do
      empty_users_table()
      {:ok, _user} = Accounts.register_user(valid_user_attributes(username: username))

      assert {:error, changeset} =
               Accounts.register_user(valid_user_attributes(username: variant))

      assert "has already been taken" in username_errors(changeset)
    end
  end

  property "register_user/1 refuses a username with any character outside the set, and inserts nothing" do
    check all(username <- username_with_a_forbidden_character(), max_runs: @max_db_runs) do
      empty_users_table()

      assert {:error, changeset} =
               Accounts.register_user(valid_user_attributes(username: username))

      assert @bad_character in username_errors(changeset)
      assert Repo.all(User) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Lookup
  # ---------------------------------------------------------------------------

  property "a registered user is found by their username in any letter case, with the username as registered, and only with their password" do
    check all(
            username <- valid_username(),
            typed <- case_variant(username),
            max_runs: @max_db_runs
          ) do
      empty_users_table()
      %{id: id} = user_fixture(username: username)

      found = Accounts.get_user_by_username_and_password(typed, valid_user_password())

      assert %User{id: ^id} = found
      assert found.username == username
      refute Accounts.get_user_by_username_and_password(typed, "not the password")
    end
  end

  # #340's hazard on the lookup side: stripping the NUL byte and then looking
  # the name up would find the user, and passing it on to Postgres raises
  # (22021, an encoding error).
  property "a NUL byte anywhere in a registered username finds nobody, and raises nothing" do
    check all(
            username <- valid_username(),
            position <- integer(0..String.length(username)),
            max_runs: @max_db_runs
          ) do
      empty_users_table()
      user_fixture(username: username)
      {before, rest} = String.split_at(username, position)

      refute Accounts.get_user_by_username_and_password(
               before <> "\0" <> rest,
               valid_user_password()
             )
    end
  end

  # ---------------------------------------------------------------------------
  # The users table
  # ---------------------------------------------------------------------------

  property "the table holds two usernames exactly when they differ by more than letter case" do
    check all({first, second} <- two_usernames(), max_runs: @max_db_runs) do
      empty_users_table()
      assert {1, nil} = insert_row(%{username: first})

      if same_username?(first, second) do
        assert_raise Postgrex.Error, ~r/unique_violation/, fn ->
          insert_row(%{username: second})
        end
      else
        assert {1, nil} = insert_row(%{username: second})
      end
    end
  end

  property "the table takes any number of rows with no email" do
    check all(
            usernames <-
              uniq_list_of(valid_username(),
                uniq_fun: &String.downcase/1,
                min_length: 1,
                max_length: 6
              ),
            max_runs: @max_db_runs
          ) do
      empty_users_table()
      rows = Enum.map(usernames, &users_row(%{username: &1}))

      assert Repo.insert_all("users", rows) == {length(rows), nil}
    end
  end

  property "the table still holds one row per email, whatever its letter case" do
    check all(
            email <- email(),
            variant <- case_variant(email),
            max_runs: @max_db_runs
          ) do
      empty_users_table()
      assert {1, nil} = insert_row(%{username: unique_user_username(), email: email})

      assert_raise Postgrex.Error, ~r/unique_violation/, fn ->
        insert_row(%{username: unique_user_username(), email: variant})
      end
    end
  end
end
