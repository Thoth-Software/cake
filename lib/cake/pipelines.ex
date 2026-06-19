defmodule Cake.Pipelines do
  @moduledoc """
  Various assorted motley helpers, doohickeys, and dongles for data ingestion pipelines. Some of this may very well be cruft.
  """

  alias Cake.Pipelines

  require Logger

  defmodule Context do
    @moduledoc """
    Carries pipeline identity through an ingest run.
    Built once at the top of each behaviour's `ingest` function
    and passed to `detuple_with_logging` so it can persist errors
    with full provenance. Also carries a keyword list of opts.
    """
    @type t :: %__MODULE__{
            behaviour: String.t(),
            implementation: String.t(),
            version: String.t(),
            opts: keyword()
          }
    defstruct [:behaviour, :implementation, :version, :opts]
  end

  @type context :: Context.t()

  @typedoc """
  Outcome of an ingest run. `indexed` is how many atomic units made it all the
  way through; `failed` is how many item-level failures were recorded during
  the run (each persisted to `FailedIngest` for later sweep). `message` is the
  pipeline's human-readable banner.
  """
  @type ingest_summary :: %{
          message: String.t(),
          indexed: non_neg_integer(),
          failed: non_neg_integer()
        }

  @spec add_to_opensearch(Enumerable.t(), String.t(), module(), context()) :: Enumerable.t()
  def add_to_opensearch(docs_with_embeddings_stream, index, cluster, %Context{} = ctx) do
    if skip_opensearch?() do
      # In test mode, just pass through the documents without calling OpenSearch
      Stream.map(docs_with_embeddings_stream, fn doc ->
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
  @spec detuple_with_logging(Enumerable.t(), String.t(), context()) :: Enumerable.t()
  def detuple_with_logging(stream_enumerable, step_name, %Context{} = ctx) do
    stream_enumerable
    |> Stream.filter(fn
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.warning("[#{step_name}] Item failed: #{inspect(reason)}")
        _ = persist_failure(ctx, step_name, reason)
        false

      other ->
        Logger.warning("[#{step_name}] Unexpected value: #{inspect(other)}")
        _ = persist_failure(ctx, step_name, other)
        false
    end)
    |> Stream.map(fn {:ok, value} -> value end)
  end

  @doc """
  Logs an item-level failure and persists it to the FailedIngest table.
  Use this from pipeline steps that handle errors manually instead of
  going through detuple_with_logging.
  """
  @spec log_and_persist_failure(context(), String.t(), term()) ::
          {:ok, Cake.FailedIngests.FailedIngest.t()} | {:error, Ecto.Changeset.t()}
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
  @spec sweep(String.t(), String.t(), String.t(), fun(), [{:max_sweeps, integer()}]) ::
          {integer(), integer()}
  def sweep(behaviour, implementation, version, retry_fn, opts \\ []) do
    max_sweeps = Keyword.get(opts, :max_sweeps, 2)
    do_sweep(behaviour, implementation, version, retry_fn, max_sweeps, 0)
  end

  defp do_sweep(behaviour, implementation, version, _retry_fn, 0, total_resolved) do
    remaining =
      length(Cake.FailedIngests.list_failed_ingests_for(behaviour, implementation, version))

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

  @doc """
  Counts the `FailedIngest` rows recorded for a pipeline run's identity.

  Used by `ingest` implementations to measure item-level failures: snapshot
  before the run, snapshot after, and the delta is how many items this run
  dropped. (Only non-fatal item failures are created inside a successful
  `with` chain; fatal failures short-circuit to `handle_ingest_error/2`.)
  """
  @spec count_failures(context()) :: non_neg_integer()
  def count_failures(%Context{} = ctx) do
    ctx.behaviour
    |> Cake.FailedIngests.list_failed_ingests_for(ctx.implementation, ctx.version)
    |> length()
  end

  @doc """
  Builds the honest result of an ingest run from its outcome counts.

  Returns `{:ok, summary}` when at least one item made it through (including a
  partial run, whose `summary.failed` is non-zero — partial success is reported
  *as* partial, never as clean success). A non-empty run where nothing made it
  through is a failure: `{:error, {:no_items_ingested, summary}}`.
  """
  @spec summarize_ingest(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, ingest_summary()} | {:error, {:no_items_ingested, ingest_summary()}}
  def summarize_ingest(message, indexed, failed)
      when is_binary(message) and is_integer(indexed) and is_integer(failed) do
    summary = %{message: message, indexed: indexed, failed: failed}

    if indexed == 0 and failed > 0 do
      {:error, {:no_items_ingested, summary}}
    else
      {:ok, summary}
    end
  end

  @doc """
  Closes out an ingest run: forces the final stream to count how many items
  made it through, measures item failures as the `count_failures/1` delta since
  `failures_before`, and builds the honest result via `summarize_ingest/3`.
  """
  @spec finalize_ingest(Enumerable.t(), context(), non_neg_integer(), String.t()) ::
          {:ok, ingest_summary()} | {:error, {:no_items_ingested, ingest_summary()}}
  def finalize_ingest(indexed_stream, %Context{} = ctx, failures_before, message) do
    indexed = Enum.count(indexed_stream)
    failed = count_failures(ctx) - failures_before
    summarize_ingest(message, indexed, failed)
  end

  @spec build_context(atom(), atom(), any(), list()) :: context()
  def build_context(behaviour_module, source_pipeline, version, opts \\ [])

  @spec build_context(atom(), atom(), {integer(), integer(), integer()}) :: context()
  def build_context(behaviour_module, source_pipeline, {major, minor, patch}, opts) do
    version = Enum.join([major, minor, patch], ".")

    %Pipelines.Context{
      behaviour: inspect(behaviour_module),
      implementation: inspect(source_pipeline),
      version: version,
      opts: opts
    }
  end

  @spec build_context(atom(), atom(), String.t()) :: context()
  def build_context(behaviour_module, source_pipeline, version, opts) do
    %Pipelines.Context{
      behaviour: inspect(behaviour_module),
      implementation: inspect(source_pipeline),
      version: version,
      opts: opts
    }
  end

  @spec handle_ingest_error({:error, any()} | {:error, atom(), any()}, context()) ::
          {:error, {atom(), any()}}
          | {:ok, Cake.FailedIngests.FailedIngest.t()}
          | {:error, Ecto.Changeset.t()}
  def handle_ingest_error({:error, step, error}, ctx) when is_atom(step) do
    Logger.warning("[#{ctx.behaviour}] Pipeline-fatal error at #{step}: #{inspect(error)}")

    _ =
      Cake.FailedIngests.create_failed_ingest(%{
        pipeline_behaviour: ctx.behaviour,
        pipeline_implementation: ctx.implementation,
        step: Atom.to_string(step),
        version: ctx.version,
        error_text: inspect(error),
        input_identifier: "",
        pipeline_fatal: true
      })

    {:error, {step, error}}
  end

  def handle_ingest_error({:error, error}, ctx) do
    Logger.warning("[#{ctx.behaviour}] Pipeline-fatal error: #{inspect(error)}")

    Cake.FailedIngests.create_failed_ingest(%{
      pipeline_behaviour: ctx.behaviour,
      pipeline_implementation: ctx.implementation,
      step: "ingest",
      version: ctx.version,
      error_text: inspect(error),
      input_identifier: "",
      pipeline_fatal: true
    })
  end
end
