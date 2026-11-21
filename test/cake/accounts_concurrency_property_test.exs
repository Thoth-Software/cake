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

  One user can also be the subject of two requests at once. The dangerous
  pair is a promotion and its undoing: a demotion or deletion that looks
  before the promotion commits (nobody is an admin, so this is not the last
  one) and acts after it. Two tests fix that interleaving exactly, by holding
  the promotion's transaction open until the database reports the second
  request waiting on a lock, and a third property races several promotions
  and demotions of the same two users from a table with no admin at all.

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
            email: "#{@username_prefix}#{n}@race.example",
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
  # One user, two requests: a promotion still uncommitted, and its undoing
  # ---------------------------------------------------------------------------

  # Found in review on #387. A request to demote or delete a user can arrive
  # while that same user's promotion is still uncommitted. If it decides from
  # what it read before the promotion committed (nobody is an admin, so this
  # cannot be the last one) and acts after, the one admin there is goes.
  #
  # These two tests hold the promotion's transaction open, start the second
  # request, wait until the database reports a session waiting on a lock, and
  # only then let the promotion commit. So the interleaving is the same on
  # every run, and nothing sleeps: the wait is a poll of `pg_stat_activity`.

  defp create_member do
    unboxed(fn ->
      {:ok, member} =
        Accounts.create_user(%{
          username: "#{@username_prefix}solo",
          email: "#{@username_prefix}solo@race.example",
          password: @password,
          role: :member
        })

      member
    end)
  end

  # Promotes `user` in a transaction that stays open until it is sent
  # `:commit`, and tells `test` once the promotion is made and uncommitted.
  defp promote_and_hold(user, test) do
    Task.async(fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          {:ok, promoted} = Accounts.update_user_role(user, :admin)
          send(test, :promotion_uncommitted)

          receive do
            :commit -> promoted
          end
        end)
      end)
    end)
  end

  defp sessions_waiting_on_a_lock do
    %{rows: [[count]]} =
      unboxed(fn ->
        Repo.query!("""
        SELECT count(*) FROM pg_stat_activity
        WHERE datname = current_database() AND wait_event_type = 'Lock'
        """)
      end)

    count
  end

  # Returns once `task` is waiting on a lock, or has already answered.
  defp await_blocked_or_done(task, polls_left \\ 20_000) do
    cond do
      sessions_waiting_on_a_lock() > 0 -> :blocked
      Task.yield(task, 0) != nil -> flunk("the request answered while the promotion was open")
      polls_left == 0 -> flunk("the request neither answered nor waited on a lock")
      true -> await_blocked_or_done(task, polls_left - 1)
    end
  end

  for {name, request} <- [
        {"demotion", quote(do: &Accounts.update_user_role(&1, :member))},
        {"deletion", quote(do: &Accounts.delete_user/1)}
      ] do
    test "a #{name} that arrives while the same user's promotion is uncommitted is refused once it commits" do
      member = create_member()
      request = unquote(request)

      promotion = promote_and_hold(member, self())
      assert_receive :promotion_uncommitted

      undoing = Task.async(fn -> unboxed(fn -> request.(member) end) end)
      assert await_blocked_or_done(undoing) == :blocked

      send(promotion.pid, :commit)
      assert {:ok, %User{}} = Task.await(promotion, 15_000)

      # The promotion committed first, so the user is the only admin.
      assert Task.await(undoing, 15_000) == {:error, :last_admin}
      assert stored_roles() == %{member.id => :admin}
    end
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

  # Several requests for the same user at once, starting from no admin at
  # all. Run one after another in any order, the first promotion makes an
  # admin and from then on there is always one. So when anything is promoted,
  # an admin is left; and when nothing is, every demotion is of a member and
  # is allowed.
  property "from no admins, whatever promotions and demotions of the same users race, an admin is left exactly when one was promoted" do
    check all(
            requests <-
              list_of(
                tuple({integer(0..1), member_of([:promote, :demote])}),
                min_length: 1,
                max_length: most_users()
              ),
            max_runs: @max_runs
          ) do
      delete_racers()
      users = create_users([{:member, :none}, {:member, :none}])

      answers =
        race(for {n, request} <- requests, do: ask(Enum.at(users, n).user, request))

      for answer <- answers do
        assert match?({:ok, %User{}}, answer) or answer == {:error, :last_admin},
               "a request was answered #{inspect(answer)}"
      end

      admin_left? = Enum.any?(stored_roles(), fn {_id, role} -> role == :admin end)
      promoted? = Enum.any?(requests, fn {_n, request} -> request == :promote end)

      assert admin_left? == promoted?
    end
  end
end
