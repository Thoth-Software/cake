defmodule Cake.AccountsPropertyTest do
  @moduledoc """
  Property tests for roles, confirmation and the last-admin rule in
  `Cake.Accounts` (#373, #405).

  There is always at least one admin: once a database has an admin, no
  demotion and no deletion leaves it with none. The context refuses the
  change that would, with `{:error, :last_admin}`.

  An admin who is not confirmed cannot log in, so that is not enough to keep
  the admin panel reachable (#405). There is also always a confirmed admin:
  once a database has one, no demotion, no deletion and no confirmation
  taken back leaves it with none. The context refuses the change that would,
  with `{:error, :last_confirmed_admin}`, and allows every other.

  The rule is checked against a model. A run creates a few users with
  generated roles, confirmed or not, then applies a generated sequence of
  promotions, demotions, deletions, confirmations by hand and confirmations
  taken back. Each role change is made by either function that can make one
  (`update_user_role/2`, or the admin panel's `update_user/2`, #376), with
  renames among them; each change of confirmation is asked by the operator
  or by one of the users (`set_user_confirmed/3`). After each step the
  answer, and the roles and confirmations in the database, must be what the
  model says. Every call is made with the struct from when the user was
  created, so its `role` and `confirmed_at` are often out of date: the rule
  has to go by the database, not by the struct it is handed.

  The model does not restate the rule clause by clause. It works out what
  the database would hold if the change were made, and refuses it exactly
  when that has no admin, or no confirmed admin, where there was one.

  Two requests racing for the last admin are in
  `test/cake/accounts_concurrency_property_test.exs`; example tests are in
  `test/cake/accounts_test.exs`.
  """

  use Cake.DataCase, async: true
  use ExUnitProperties

  import Cake.AccountsFixtures

  alias Cake.Accounts
  alias Cake.Accounts.User

  # Each iteration inserts users and changes them.
  @max_runs 40

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp role, do: member_of([:member, :admin])

  # A user to start a run with: a role, and whether they are confirmed.
  defp starting_user, do: tuple({role(), boolean()})

  # `{operation, n, m}`: `n` picks the user it is done to, modulo how many
  # the run created. `m` picks who asks for a change of confirmation: one of
  # the users still there, or the operator.
  defp operation do
    tuple({
      member_of([
        :promote,
        :demote,
        :delete,
        :update_to_admin,
        :update_to_member,
        :rename,
        :confirm,
        :unconfirm
      ]),
      non_negative_integer(),
      non_negative_integer()
    })
  end

  # A role as a form or a caller might send it: the two real ones, as atoms
  # and as strings, among arbitrary other names. Never blank: a blank role is
  # no role given, which `create_user/1` refuses as missing, not as invalid
  # (an example in `accounts_test.exs`).
  defp candidate_role do
    one_of([
      member_of([:member, :admin, "member", "admin"]),
      atom(:alphanumeric),
      string(:alphanumeric, min_length: 1, max_length: 12)
    ])
  end

  # ---------------------------------------------------------------------------
  # The model
  # ---------------------------------------------------------------------------

  # The model is the users still there, by their index in the run:
  # `%{index => {role, confirmed?}}`.

  defp admins(model),
    do: Enum.count(model, fn {_index, {role, _confirmed?}} -> role == :admin end)

  defp confirmed_admins(model), do: Enum.count(model, &match?({_index, {:admin, true}}, &1))

  # What the model would be if the change were made.
  defp made(model, :promote, index), do: Map.update!(model, index, &put_elem(&1, 0, :admin))
  defp made(model, :demote, index), do: Map.update!(model, index, &put_elem(&1, 0, :member))
  defp made(model, :delete, index), do: Map.delete(model, index)
  defp made(model, :confirm, index), do: Map.update!(model, index, &put_elem(&1, 1, true))
  defp made(model, :unconfirm, index), do: Map.update!(model, index, &put_elem(&1, 1, false))

  # `update_user/2` (#376) is a second way to change a role, so it is held to
  # the same rule: as a promotion, as a demotion, and when it leaves the role
  # alone.
  defp made(model, :update_to_admin, index), do: made(model, :promote, index)
  defp made(model, :update_to_member, index), do: made(model, :demote, index)
  defp made(model, :rename, _index), do: model

  # The whole rule: a change is refused when it would leave no admin, or no
  # confirmed admin, where there was one. The first is named when both hold.
  defp refusal(model, made) do
    cond do
      admins(model) > 0 and admins(made) == 0 -> :last_admin
      confirmed_admins(model) > 0 and confirmed_admins(made) == 0 -> :last_confirmed_admin
      true -> nil
    end
  end

  # What the context must answer, and the model after it. Nobody takes back
  # their own confirmation, whatever else is true: that is decided first.
  defp expect(_model, :unconfirm, index, index), do: :own_account

  defp expect(model, operation, index, _asker) do
    made = made(model, operation, index)
    refusal(model, made) || {:ok, made}
  end

  # Who asks: the operator, or one of the users still in the model.
  defp asker(model, m) do
    present = model |> Map.keys() |> Enum.sort()

    case rem(m, length(present) + 1) do
      0 -> :operator
      position -> Enum.at(present, position - 1)
    end
  end

  defp apply_operation(:promote, user, _asker), do: Accounts.update_user_role(user, :admin)
  defp apply_operation(:demote, user, _asker), do: Accounts.update_user_role(user, :member)
  defp apply_operation(:delete, user, _asker), do: Accounts.delete_user(user)

  defp apply_operation(:update_to_admin, user, _asker),
    do: Accounts.update_user(user, %{role: :admin})

  defp apply_operation(:update_to_member, user, _asker),
    do: Accounts.update_user(user, %{role: :member})

  defp apply_operation(:rename, user, _asker),
    do: Accounts.update_user(user, %{username: unique_user_username()})

  defp apply_operation(:confirm, user, asker), do: Accounts.set_user_confirmed(asker, user, true)

  defp apply_operation(:unconfirm, user, asker),
    do: Accounts.set_user_confirmed(asker, user, false)

  # A user with a role, confirmed or not, made through the context: a
  # created user is confirmed from the start, and a registered one is an
  # unconfirmed member until promoted. Neither way meets the rule.
  defp create(role, true) do
    {:ok, user} = Accounts.create_user(valid_user_attributes(role: role))
    user
  end

  defp create(role, false) do
    {:ok, member} = Accounts.register_user(valid_user_attributes())
    {:ok, user} = Accounts.update_user_role(member, role)
    user
  end

  # The roles and confirmations in the database, keyed like the model.
  defp stored(users) do
    rows = Map.new(Repo.all(User), &{&1.id, {&1.role, not is_nil(&1.confirmed_at)}})

    for {index, user} <- users, Map.has_key?(rows, user.id), into: %{} do
      {index, Map.fetch!(rows, user.id)}
    end
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "a demotion, a deletion or a confirmation taken back is refused exactly when it would leave no admin, or no confirmed admin, where there was one, whatever came before" do
    check all(
            starting <- list_of(starting_user(), min_length: 1, max_length: 5),
            operations <- list_of(operation(), max_length: 16),
            max_runs: @max_runs
          ) do
      Repo.delete_all(User)

      users =
        for {{role, confirmed?}, index} <- Enum.with_index(starting), into: %{} do
          {index, create(role, confirmed?)}
        end

      model = Map.new(Enum.with_index(starting), fn {user, index} -> {index, user} end)
      assert stored(users) == model

      Enum.reduce(operations, model, fn {operation, n, m}, model ->
        index = rem(n, length(starting))

        # A deleted user is not operated on again.
        if Map.has_key?(model, index) do
          asker = asker(model, m)
          asking = if asker == :operator, do: :operator, else: Map.fetch!(users, asker)
          result = apply_operation(operation, Map.fetch!(users, index), asking)

          case expect(model, operation, index, asker) do
            {:ok, next_model} ->
              assert {:ok, %User{}} = result
              assert stored(users) == next_model
              next_model

            refused ->
              assert result == {:error, refused}
              assert stored(users) == model
              model
          end
        else
          model
        end
      end)
    end
  end

  property "create_user/1 takes the roles member and admin, as atoms or strings, and no other name" do
    check all(role <- candidate_role(), max_runs: @max_runs) do
      Repo.delete_all(User)
      result = Accounts.create_user(valid_user_attributes(role: role))

      if role in [:member, :admin, "member", "admin"] do
        assert {:ok, user} = result
        assert to_string(user.role) == to_string(role)
      else
        assert {:error, changeset} = result
        assert errors_on(changeset).role == ["is invalid"]
        assert Repo.all(User) == []
      end
    end
  end
end
