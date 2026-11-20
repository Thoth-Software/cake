defmodule Cake.AccountsConcurrencyTest do
  @moduledoc """
  The last-admin rule under concurrent requests (#373).

  Eight admins, and eight requests released together, each demoting or
  deleting a different one. Whatever the interleaving, exactly one request
  is refused with `{:error, :last_admin}` and exactly one admin is left. A
  rule that counts the admins and then acts (a check and an update with
  nothing holding the count still between them) lets every request through
  and leaves none.

  The SQL sandbox gives a test one connection, on which nothing can race. So
  this module does not use it: every database call runs through
  `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`, on a connection of its own, and
  commits. That is why the module is `async: false` (no sandboxed test is
  running to see the committed rows), why each test deletes its users
  afterwards, and why it first deletes any a killed run left behind.

  The requests are released by a message and collected with
  `Task.await_many/2`; nothing sleeps.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Cake.Accounts
  alias Cake.Accounts.User
  alias Cake.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @racers 8
  @rounds 5
  @username_prefix "racer-"
  @password "hello world!"

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp racers, do: from(u in User, where: like(u.username, ^"#{@username_prefix}%"))

  defp delete_racers, do: unboxed(fn -> Repo.delete_all(racers()) end)

  defp create_admins do
    unboxed(fn ->
      for n <- 1..@racers do
        {:ok, admin} =
          Accounts.create_user(%{
            username: "#{@username_prefix}#{n}",
            password: @password,
            role: :admin
          })

        admin
      end
    end)
  end

  # Starts one process per request, each waiting for `:go` on a connection
  # of its own, releases them together, and returns their answers in order.
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

  defp admins_left, do: unboxed(fn -> Repo.aggregate(where(User, role: :admin), :count) end)

  setup do
    delete_racers()
    on_exit(&delete_racers/0)
  end

  test "of eight admins demoted at once, one is refused and one admin is left" do
    for _round <- 1..@rounds do
      delete_racers()
      admins = create_admins()

      results = race(for admin <- admins, do: fn -> Accounts.update_user_role(admin, :member) end)

      assert Enum.count(results, &(&1 == {:error, :last_admin})) == 1
      assert Enum.count(results, &match?({:ok, %User{}}, &1)) == @racers - 1
      assert admins_left() == 1
    end
  end

  test "of eight admins deleted at once, one is refused and one admin is left" do
    for _round <- 1..@rounds do
      delete_racers()
      admins = create_admins()

      results = race(for admin <- admins, do: fn -> Accounts.delete_user(admin) end)

      assert Enum.count(results, &(&1 == {:error, :last_admin})) == 1
      assert Enum.count(results, &match?({:ok, %User{}}, &1)) == @racers - 1
      assert admins_left() == 1
    end
  end

  test "of eight admins, half demoted and half deleted at once, one is refused and one admin is left" do
    for _round <- 1..@rounds do
      delete_racers()
      admins = create_admins()

      requests =
        for {admin, n} <- Enum.with_index(admins) do
          if rem(n, 2) == 0 do
            fn -> Accounts.update_user_role(admin, :member) end
          else
            fn -> Accounts.delete_user(admin) end
          end
        end

      results = race(requests)

      assert Enum.count(results, &(&1 == {:error, :last_admin})) == 1
      assert Enum.count(results, &match?({:ok, %User{}}, &1)) == @racers - 1
      assert admins_left() == 1
    end
  end
end
