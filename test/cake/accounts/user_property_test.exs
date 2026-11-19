defmodule Cake.Accounts.UserPropertyTest do
  @moduledoc """
  Property tests for the username rules of `Cake.Accounts.User` (#372).

  A username is 3 to 32 characters from `a-z`, `0-9`, `_`, `.` and `-`.
  Letters are accepted in either case: the name is stored as typed and
  compared case-insensitively. Anything else, a NUL byte included, is a
  validation error.

  The shape rules run through `Cake.Accounts.change_user_registration/2`,
  which neither queries the Repo nor hashes a password. Uniqueness needs the
  Repo, so its property goes through `Cake.Accounts.register_user/1`. Example
  tests, the known hazards among them, live in `test/cake/accounts_test.exs`.
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

  # Each iteration of the uniqueness property registers a user.
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

  # Runs one iteration's inserts and takes them back, pass or fail, so no
  # iteration (and no shrink step) sees a name an earlier one registered.
  defp rolled_back(fun) do
    Repo.transaction(fn ->
      fun.()
      Repo.rollback(:iteration_done)
    end)
  end

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
  # Uniqueness
  # ---------------------------------------------------------------------------

  property "a username that differs from a registered one only in letter case is already taken" do
    check all(
            username <- valid_username(),
            variant <- case_variant(username),
            max_runs: @max_db_runs
          ) do
      rolled_back(fn ->
        {:ok, _user} = Accounts.register_user(valid_user_attributes(username: username))

        assert {:error, changeset} =
                 Accounts.register_user(valid_user_attributes(username: variant))

        assert "has already been taken" in username_errors(changeset)
      end)
    end
  end
end
