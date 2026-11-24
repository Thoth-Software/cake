defmodule Cake.ConcurrencyHelpers do
  @moduledoc """
  Fixes one interleaving of two requests on real connections, the same on
  every run, without sleeping.

  The SQL sandbox gives a test one connection, on which nothing can race.
  So a test that races requests runs each database call through `unboxed/1`,
  outside the sandbox, on a connection of its own, and commits. Such a test
  module is `async: false` (no sandboxed test is running to see the
  committed rows), and deletes what it made, first anything a killed run
  left behind: `Cake.AccountsConcurrencyPropertyTest`'s moduledoc has the
  rest.

  The interleaving: `change_and_hold/2` makes a first change and keeps its
  transaction open; the second request is started in a task of its own;
  `await_blocked_or_done/2` returns once the database reports a session
  waiting on a lock; and only then is the first change sent `:commit`. A
  test that holds a transaction open uses three connections at once (the
  held one, the second request, and the poll that watches for the wait).
  """

  import ExUnit.Assertions

  alias Cake.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @doc """
  Runs `fun` outside the SQL sandbox, on a connection of its own, where
  what it writes is committed.
  """
  @spec unboxed((-> result)) :: result when result: term()
  def unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  @doc """
  Makes `change` in a transaction that stays open until it is sent
  `:commit`, and sends `test` `:change_uncommitted` once the change is made.

  `change` answers `{:ok, changed}`; the task answers
  `{:ok, changed}` once it has committed.
  """
  @spec change_and_hold((-> {:ok, term()}), pid()) :: Task.t()
  def change_and_hold(change, test) when is_function(change, 0) and is_pid(test) do
    Task.async(fn ->
      unboxed(fn ->
        Repo.transaction(fn ->
          {:ok, changed} = change.()
          send(test, :change_uncommitted)

          receive do
            :commit -> changed
          end
        end)
      end)
    end)
  end

  @doc """
  Returns `:blocked` once a session is waiting on a lock, and fails the test
  if `task` answers first.

  It does not say which session waits, or on which lock: a request that
  decided on what it could see and then waits to write is `:blocked` too.
  What the request answers, and what the database holds afterwards, are what
  each test goes by.
  """
  @spec await_blocked_or_done(Task.t(), non_neg_integer()) :: :blocked
  def await_blocked_or_done(%Task{} = task, polls_left \\ 20_000) do
    cond do
      sessions_waiting_on_a_lock() > 0 -> :blocked
      Task.yield(task, 0) != nil -> flunk("the request answered while the first change was open")
      polls_left == 0 -> flunk("the request neither answered nor waited on a lock")
      true -> await_blocked_or_done(task, polls_left - 1)
    end
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
end
