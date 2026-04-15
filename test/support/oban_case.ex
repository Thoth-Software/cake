defmodule Cake.ObanCase do
  @moduledoc """
  This module defines the setup for tests requiring Oban.

  It provides helpers for testing Oban jobs, including setting up
  the Oban testing mode and utilities for working with job queues.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Cake.ObanCase

      alias Cake.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
    end
  end

  setup tags do
    Cake.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Drains all jobs from the specified queue.

  Returns a list of completed job results.

  ## Examples

      assert {:ok, [result]} = drain_jobs(:default)
  """
  @spec drain_jobs(atom()) :: map()
  def drain_jobs(queue_name \\ :default) do
    Oban.drain_queue(queue: queue_name)
  end

  @doc """
  Returns all jobs in the specified queue.

  ## Examples

      jobs = all_enqueued_jobs(:default)
      assert length(jobs) == 1
  """
  @spec all_enqueued_jobs(atom()) :: [Oban.Job.t()]
  def all_enqueued_jobs(queue_name \\ :default) do
    import Ecto.Query

    Cake.Repo.all(
      from j in Oban.Job,
        where: j.queue == ^to_string(queue_name),
        order_by: [asc: j.id]
    )
  end

  @doc """
  Returns the count of jobs in the specified queue.

  ## Examples

      assert jobs_count(:default) == 1
  """
  @spec jobs_count(atom()) :: non_neg_integer()
  def jobs_count(queue_name \\ :default) do
    import Ecto.Query

    Cake.Repo.one(
      from j in Oban.Job,
        where: j.queue == ^to_string(queue_name),
        select: count(j.id)
    )
  end
end
