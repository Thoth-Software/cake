defmodule Cake.AccountsPropertyTest do
  @moduledoc """
  Property tests for roles and the last-admin rule in `Cake.Accounts` (#373).

  There is always at least one admin: once a database has an admin, no
  demotion and no deletion leaves it with none. The context refuses the
  change that would, with `{:error, :last_admin}`, and allows every other.

  The rule is checked against a model. A run creates a few users with
  generated roles, then applies a generated sequence of promotions,
  demotions and deletions, each role change made by either function that
  can make one (`update_user_role/2`, or the admin panel's `update_user/2`,
  #376), with renames among them; after each step the answer and the roles in the
  database must be what the model says. Every call is made with the struct
  from when the user was created, so its `role` is often out of date: the
  rule has to go by the database, not by the struct it is handed.

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

  # `{operation, n}`: `n` picks a user, modulo how many the run created.
  defp operation do
    tuple({
      member_of([:promote, :demote, :delete, :update_to_admin, :update_to_member, :rename]),
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

  defp admins(model), do: Enum.count(model, fn {_index, role} -> role == :admin end)

  defp last_admin?(model, index), do: model[index] == :admin and admins(model) == 1

  # What the context must answer, and the model after it.
  defp expect(model, :promote, index), do: {:ok, Map.put(model, index, :admin)}

  defp expect(model, :demote, index) do
    if last_admin?(model, index),
      do: {:refused, model},
      else: {:ok, Map.put(model, index, :member)}
  end

  # `update_user/2` (#376) is a second way to change a role, so it is held to
  # the same rule: as a promotion, as a demotion, and when it leaves the role
  # alone.
  defp expect(model, :update_to_admin, index), do: expect(model, :promote, index)
  defp expect(model, :update_to_member, index), do: expect(model, :demote, index)
  defp expect(model, :rename, _index), do: {:ok, model}

  defp expect(model, :delete, index) do
    if last_admin?(model, index), do: {:refused, model}, else: {:ok, Map.delete(model, index)}
  end

  defp apply_operation(:promote, user), do: Accounts.update_user_role(user, :admin)
  defp apply_operation(:demote, user), do: Accounts.update_user_role(user, :member)
  defp apply_operation(:delete, user), do: Accounts.delete_user(user)
  defp apply_operation(:update_to_admin, user), do: Accounts.update_user(user, %{role: :admin})
  defp apply_operation(:update_to_member, user), do: Accounts.update_user(user, %{role: :member})

  defp apply_operation(:rename, user),
    do: Accounts.update_user(user, %{username: unique_user_username()})

  # The roles in the database, keyed like the model.
  defp stored_roles(users) do
    roles = Map.new(Repo.all(User), &{&1.id, &1.role})

    for {index, user} <- users, Map.has_key?(roles, user.id), into: %{} do
      {index, Map.fetch!(roles, user.id)}
    end
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "a demotion or deletion is refused exactly when it would leave no admin, whatever came before" do
    check all(
            roles <- list_of(role(), min_length: 1, max_length: 5),
            operations <- list_of(operation(), max_length: 12),
            max_runs: @max_runs
          ) do
      Repo.delete_all(User)

      users =
        for {role, index} <- Enum.with_index(roles), into: %{} do
          {:ok, user} = Accounts.create_user(valid_user_attributes(role: role))
          {index, user}
        end

      model = Map.new(Enum.with_index(roles), fn {role, index} -> {index, role} end)
      assert stored_roles(users) == model

      Enum.reduce(operations, model, fn {operation, n}, model ->
        index = rem(n, length(roles))

        # A deleted user is not operated on again.
        if Map.has_key?(model, index) do
          {expected, next_model} = expect(model, operation, index)
          result = apply_operation(operation, Map.fetch!(users, index))

          case expected do
            :ok -> assert {:ok, %User{}} = result
            :refused -> assert result == {:error, :last_admin}
          end

          assert stored_roles(users) == next_model
          next_model
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
