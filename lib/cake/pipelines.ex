defmodule Cake.Pipelines do
  @moduledoc """
  Various assorted motley helpers, doohickeys, and dongles for data ingestion pipelines. Some of this may very well be cruft.
  """

  defmodule Context do
    @moduledoc """
    Carries pipeline identity through an ingest run.
    Built once at the top of each behaviour's `ingest` function
    and passed to `detuple_with_logging` so it can persist errors
    with full provenance.
    """
    defstruct [:behaviour, :implementation, :version]
  end

  require Logger

  def add_to_opensearch(docs_with_embeddings_stream, index, cluster, %Context{} = ctx) do
    if skip_opensearch?() do
      # In test mode, just pass through the documents without calling OpenSearch
      docs_with_embeddings_stream
      |> Stream.map(fn doc ->
        Logger.debug("Skipping OpenSearch insert for document #{doc.id} (test mode)")
        doc
      end)
    else
      docs_with_embeddings_stream
      |> Task.async_stream(
        &Snap.Document.update(cluster, index, %{doc: &1, doc_as_upsert: true}, &1.id),
        max_concurrency: 5,
        timeout: 5_000,
        on_timeout: :kill_task
      )
      |> Stream.map(&handle_opensearch_response/1)
      |> detuple_with_logging("opensearch.index", ctx)
    end
  end

  defp skip_opensearch? do
    Application.get_env(:cake, :skip_opensearch, false)
  end

  defp handle_opensearch_response({:exit, element}),
    do: {:error, {:opensearch_exit, element}}

  defp handle_opensearch_response({:ok, task_response}),
    do: handle_opensearch_task_result(task_response)

  defp handle_opensearch_response({:error, changeset}),
    do: {:error, {:opensearch_changeset, changeset}}

  defp handle_opensearch_task_result({:ok, task_response}),
    do: handle_opensearch_task_result(task_response)

  defp handle_opensearch_task_result({:error, error}),
    do: {:error, {:opensearch_api_error, error}}

  defp handle_opensearch_task_result(%{"_id" => id}) do
    Logger.info("Document #{id} created")
    {:ok, id}
  end

  @doc """
  Filters a stream of {:ok, value} | {:error, reason} tuples,
  logging errors, persisting them to `FailedIngest`, and passing through successes.

  The `step_name` parameter identifies which pipeline stage failed,
  for log readability.
  """
  def detuple_with_logging(stream_enumerable, step_name, %Context{} = ctx) do
    stream_enumerable
    |> Stream.filter(fn
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.warning("[#{step_name}] Item failed: #{inspect(reason)}")
        persist_failure(ctx, step_name, reason)
        false

      other ->
        Logger.warning("[#{step_name}] Unexpected value: #{inspect(other)}")
        persist_failure(ctx, step_name, other)
        false
    end)
    |> Stream.map(fn {:ok, value} -> value end)
  end

  @doc """
  Logs an item-level failure and persists it to the FailedIngest table.
  Use this from pipeline steps that handle errors manually instead of
  going through detuple_with_logging.
  """
  def log_and_persist_failure(%Context{} = ctx, step_name, reason) do
    Logger.warning("[#{step_name}] Item failed: #{inspect(reason)}")
    persist_failure(ctx, step_name, reason)
  end

  defp persist_failure(%Context{} = ctx, step_name, reason) do
    {input_id, error_text} = extract_error_info(reason)

    Cake.FailedIngests.create_failed_ingest(%{
      pipeline_behaviour: ctx.behaviour,
      pipeline_implementation: ctx.implementation,
      step: step_name,
      version: ctx.version,
      error_text: error_text,
      input_identifier: input_id,
      pipeline_fatal: false
    })
  end

  defp extract_error_info({identifier, message})
       when is_binary(identifier) and is_binary(message) do
    {identifier, message}
  end

  defp extract_error_info({identifier, reason}) when is_binary(identifier) do
    {identifier, inspect(reason)}
  end

  defp extract_error_info(reason) do
    {nil, inspect(reason)}
  end

  @doc """
  Retries item-level failures for a given pipeline run. Queries FailedIngests
  for non-fatal failures matching the given behaviour/implementation/version,
  calls the provided retry function on each, and loops until clean or max
  sweeps reached.

  The `retry_fn` argument is a 1-arity function that accepts a %FailedIngest{}
  and returns {:ok, :retried} | {:error, any()}.

  Returns {resolved_count, remaining_count}.
  """
  # NOTE: If we end up with many more behaviours, this sweep + ingest_with_sweep
  # pattern could be extracted into a macro. For now, the duplication is minimal
  # and the explicitness is worth it.
  def sweep(behaviour, implementation, version, retry_fn, opts \\ []) do
    max_sweeps = Keyword.get(opts, :max_sweeps, 2)
    do_sweep(behaviour, implementation, version, retry_fn, max_sweeps, 0)
  end

  defp do_sweep(behaviour, implementation, version, _retry_fn, 0, total_resolved) do
    remaining =
      Cake.FailedIngests.list_failed_ingests_for(behaviour, implementation, version)
      |> length()

    {total_resolved, remaining}
  end

  defp do_sweep(behaviour, implementation, version, retry_fn, sweeps_left, total_resolved) do
    failures = Cake.FailedIngests.list_failed_ingests_for(behaviour, implementation, version)

    if failures == [] do
      {total_resolved, 0}
    else
      resolved_this_sweep =
        Enum.count(failures, fn failure ->
          case retry_fn.(failure) do
            {:ok, :retried} ->
              true

            {:error, reason} ->
              Logger.warning("[sweep] Retry failed for #{failure.id}: #{inspect(reason)}")
              false
          end
        end)

      if resolved_this_sweep == 0 do
        # No progress — stop early, remaining failures are probably permanent
        {total_resolved, length(failures)}
      else
        do_sweep(
          behaviour,
          implementation,
          version,
          retry_fn,
          sweeps_left - 1,
          total_resolved + resolved_this_sweep
        )
      end
    end
  end

  def detuple(stream_enumerable) do
    stream_enumerable
    |> Stream.filter(fn
      {:ok, _} -> true
      _ -> false
    end)
    |> Stream.map(fn {:ok, value} -> value end)
  end
end
