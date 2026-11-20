defmodule Cake.AccountsConcurrencyPropertyTest do
  @moduledoc """
  The last-admin rule under concurrent requests (#373).

  A run creates a few admins and members, decides what is asked of each
  (demote, delete, promote, or nothing), and releases every request at the
  same moment. Whatever the interleaving:

    * every request is answered, with `{:ok, user}` or `{:error, :last_admin}`,
      and only the demotion or deletion of an admin is ever refused;
    * the database ends as if exactly the requests answered `:ok` had been
      applied, and it still has an admin;
    * no more is refused than the rule needs. With `a` admins, `r` of them
      asked to step down or be deleted, and nobody promoted, exactly
      `max(0, r - (a - 1))` requests are refused: all of them go through
      while an admin would remain, and no further.

  The last point cuts both ways. A rule that counts the admins and then acts,
  with nothing holding the count still in between, refuses too few and leaves
  no admin. A rule that locks too coarsely, or goes by a stale count, refuses
  requests it should have allowed.

  When members are promoted in the same instant the exact count depends on
  who commits first, so the second property gives the range: a promotion that
  lands first can spare one refusal, and no more.

  The SQL sandbox gives a test one connection, on which nothing can race. So
  this module does not use it: every database call runs through
  `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`, on a connection of its own, and
  commits. That is why the module is `async: false` (no sandboxed test is
  running to see the committed rows), why each run deletes its users, and why
  it first deletes any a killed run left behind. No run asks for more
  requests at once than the pool has connections.

  The requests are released by a message and collected with
  `Task.await_many/2`; nothing sleeps. A failure here comes from an
  interleaving, so a shrunk counterexample may not fail again when re-run:
  read the generated values as "a case that failed once", not as the smallest
  one. The same rule without concurrency, checked against a model step by
  step, is in `test/cake/accounts_property_test.exs`.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  import Ecto.Query

  alias Cake.Accounts
  alias Cake.Accounts.User
  alias Cake.Repo
  alias Ecto.Adapters.SQL.Sandbox

  # Each run commits users and races real connections.
  @max_runs 30

  @username_prefix "racer-"
  @password "hello world!"

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  # One request runs on one connection, so a run has at most as many users as
  # the pool has connections, and at most eight.
  defp most_users, do: min(8, Repo.config()[:pool_size])

  # Mostly asked to step down or be deleted: contention for the last admin is
  # the case this file is for.
  defp admin_request do
    frequency([{4, member_of([:demote, :delete])}, {1, constant(:none)}])
  end

  # A population: `{role, request}` per user, with at least one admin.
  defp population(member_requests) do
    gen all(
          admins <- list_of(admin_request(), min_length: 1, max_length: most_users()),
          members <-
            list_of(member_of(member_requests), max_length: most_users() - length(admins))
        ) do
      Enum.map(admins, &{:admin, &1}) ++ Enum.map(members, &{:member, &1})
    end
  end

  # ---------------------------------------------------------------------------
  # Running a population
  # ---------------------------------------------------------------------------

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp racers, do: from(u in User, where: like(u.username, ^"#{@username_prefix}%"))

  defp delete_racers, do: unboxed(fn -> Repo.delete_all(racers()) end)

  defp create_users(population) do
    unboxed(fn ->
      for {{role, request}, n} <- Enum.with_index(population) do
        {:ok, user} =
          Accounts.create_user(%{
            username: "#{@username_prefix}#{n}",
            password: @password,
            role: role
          })

        %{user: user, role: role, request: request}
      end
    end)
  end

  defp ask(user, :promote), do: fn -> Accounts.update_user_role(user, :admin) end
  defp ask(user, :demote), do: fn -> Accounts.update_user_role(user, :member) end
  defp ask(user, :delete), do: fn -> Accounts.delete_user(user) end

  # Starts one process per request, each waiting for `:go` on a connection of
  # its own, releases them together, and returns their answers in order.
  defp race(requests) do
    tasks =
      for request <- requests do
        Task.async(fn ->
          receive do
            :go -> unboxed(request)
          end
        end)
      end

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 15_000)
  end

  # Creates the population, races what is asked of it, and returns each user
  # with the answer to their request (`:not_asked` for a user asked nothing).
  defp run(population) do
    delete_racers()
    users = create_users(population)

    asked = Enum.reject(users, &(&1.request == :none))
    answers = race(for %{user: user, request: request} <- asked, do: ask(user, request))

    answered =
      Map.new(Enum.zip(asked, answers), fn {asked, answer} -> {asked.user.id, answer} end)

    for user <- users, do: Map.put(user, :answer, Map.get(answered, user.user.id, :not_asked))
  end

  # ---------------------------------------------------------------------------
  # What must hold
  # ---------------------------------------------------------------------------

  defp refused?(%{answer: answer}), do: answer == {:error, :last_admin}

  defp removal?(%{role: role, request: request}),
    do: role == :admin and request in [:demote, :delete]

  # The role a user ends with if the database applied exactly the requests
  # answered `:ok`; `:deleted` for a user who is gone.
  defp role_after(%{answer: {:ok, %User{}}, request: :promote}), do: :admin
  defp role_after(%{answer: {:ok, %User{}}, request: :demote}), do: :member
  defp role_after(%{answer: {:ok, %User{}}, request: :delete}), do: :deleted
  defp role_after(%{role: role}), do: role

  defp stored_roles do
    unboxed(fn -> Map.new(Repo.all(racers()), &{&1.id, &1.role}) end)
  end

  # An answer is `{:ok, user}` or the refusal, and only a request that removes
  # an admin is ever refused.
  defp assert_answer(%{answer: :not_asked}), do: :ok
  defp assert_answer(%{answer: {:ok, %User{}}}), do: :ok

  defp assert_answer(%{answer: {:error, :last_admin}} = user) do
    assert removal?(user), "refused a request that removes no admin"
  end

  defp assert_answer(%{answer: answer}), do: flunk("a request was answered #{inspect(answer)}")

  # The checks every run owes, whatever was asked.
  defp assert_consistent(users) do
    Enum.each(users, &assert_answer/1)

    stored = stored_roles()

    for user <- users do
      assert Map.get(stored, user.user.id, :deleted) == role_after(user)
    end

    assert Enum.any?(stored, fn {_id, role} -> role == :admin end), "no admin is left"
  end

  # The refusals the rule needs when nobody is promoted: every removal goes
  # through while an admin would remain.
  defp refusals_needed(users) do
    admins = Enum.count(users, &(&1.role == :admin))
    max(0, Enum.count(users, &removal?/1) - (admins - 1))
  end

  setup do
    delete_racers()
    on_exit(&delete_racers/0)
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "of requests made at once, exactly those that would leave no admin are refused" do
    check all(population <- population([:demote, :delete, :none]), max_runs: @max_runs) do
      users = run(population)

      assert_consistent(users)
      assert Enum.count(users, &refused?/1) == refusals_needed(users)
    end
  end

  property "with members promoted in the same instant, an admin still remains and a promotion spares at most one refusal" do
    check all(
            population <- population([:promote, :promote, :demote, :delete, :none]),
            max_runs: @max_runs
          ) do
      users = run(population)

      assert_consistent(users)

      promotions = Enum.count(users, &(&1.role == :member and &1.request == :promote))
      most = refusals_needed(users)
      least = max(0, most - promotions)

      assert Enum.count(users, &refused?/1) in least..most
    end
  end
end
