defmodule Cake.Pipelines do
  @moduledoc """
  Shared infrastructure for the ingestion pipeline behaviours
  (`Cake.Books.Pipeline` and `Cake.Documents.Pipeline`).

  Owns the pieces both pipelines need but neither should re-implement:

    * `detuple_with_logging/3` — filters `{:ok, _}`/`{:error, _}` streams,
      persisting failures to `FailedIngest` instead of silently dropping
      them.
    * `add_to_search_backend/3` — indexes embedded records into a search
      collection.
    * `sweep/3` — retry loop over the item-level failures one run persisted.
    * `build_context/3` and `Context` — pipeline identity threaded through
      a run for error provenance.
    * `count_failures/1`, `summarize_ingest/3`, `finalize_ingest/3`, and
      `handle_ingest_error/2` — honest run accounting.
  """

  use Boundary, top_level?: true, deps: [Cake, Cake.Search], exports: [Context]

  alias Cake.Pipelines
  alias Cake.Search.Backend

  require Logger

  defmodule Context do
    @moduledoc """
    Carries pipeline identity through an ingest run.
    Built once at the top of each behaviour's `ingest` function
    and passed to `detuple_with_logging` so it can persist errors
    with full provenance. Also carries a keyword list of opts.

    `run_id` is a fresh UUID per `build_context/4` call. Behaviour,
    implementation, and version say *what* a run ingested; `run_id` says
    *which* run, so concurrent runs of the same source never count or
    sweep each other's failures.
    """
    @type t :: %__MODULE__{
            run_id: Ecto.UUID.t(),
            behaviour: String.t(),
            implementation: String.t(),
            version: String.t(),
            opts: keyword()
          }
    defstruct [:run_id, :behaviour, :implementation, :version, :opts]
  end

  @type context :: Context.t()

  @default_search_backend_timeout 5_000

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

  @doc """
  Indexes a stream of embedded records into `collection` on the configured
  search backend, fanning out up to five concurrent `index_document` calls.
  Per-item failures (including timeouts) are logged and persisted via
  `detuple_with_logging/3` under the `"search_backend.index"` step name,
  keyed on the failing record's `id` so `sweep/3` can retry it. Each call
  must finish within the context's `:search_backend_timeout` opt (default
  5000 ms). Skipped entirely when `config :cake, :skip_search_backend` is
  true (the test helper sets it).
  """
  @spec add_to_search_backend(Enumerable.t(), String.t(), context()) :: Enumerable.t()
  def add_to_search_backend(docs_with_embeddings_stream, collection, %Context{} = ctx) do
    if skip_search_backend?() do
      Stream.map(docs_with_embeddings_stream, fn doc ->
        Logger.debug("Skipping search backend insert for document #{doc.id} (test mode)")
        doc
      end)
    else
      backend = Backend.backend()

      docs_with_embeddings_stream
      |> Task.async_stream(
        &{&1.id, backend.index_document(collection, &1, &1.id)},
        max_concurrency: 5,
        timeout: search_backend_timeout(ctx),
        on_timeout: :kill_task,
        zip_input_on_exit: true
      )
      |> Stream.map(&handle_backend_response/1)
      |> detuple_with_logging("search_backend.index", ctx)
    end
  end

  defp skip_search_backend? do
    Application.get_env(:cake, :skip_search_backend, false)
  end

  defp search_backend_timeout(%Context{opts: opts}) do
    Keyword.get(opts, :search_backend_timeout, @default_search_backend_timeout)
  end

  # Every shape carries the document id first so extract_error_info/1 records
  # it as the failure's input_identifier.
  defp handle_backend_response({:ok, {_id, :ok}}),
    do: {:ok, :indexed}

  defp handle_backend_response({:ok, {id, {:error, error}}}),
    do: {:error, {id, {:search_backend_api_error, error}}}

  defp handle_backend_response({:exit, {%{id: id}, reason}}),
    do: {:error, {id, {:search_backend_exit, reason}}}

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

    %{
      run_id: ctx.run_id,
      pipeline_behaviour: ctx.behaviour,
      pipeline_implementation: ctx.implementation,
      step: step_name,
      version: ctx.version,
      error_text: error_text,
      input_identifier: input_id,
      pipeline_fatal: false
    }
    |> Cake.FailedIngests.create_failed_ingest()
    |> log_rejected_failure(step_name, input_id)
  end

  # A FailedIngest row is the only record an item failure leaves behind, and
  # finalize_ingest/3 counts those rows, so a rejected insert must be loud:
  # silently dropping it turns a failed run into a clean summary.
  defp log_rejected_failure({:ok, _} = ok, _step_name, _input_id), do: ok

  defp log_rejected_failure({:error, %Ecto.Changeset{} = changeset} = error, step_name, input_id) do
    Logger.error(
      "[#{step_name}] Could not persist FailedIngest for #{inspect(input_id)}: " <>
        inspect(changeset.errors)
    )

    error
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
  Retries item-level failures for one pipeline run. Queries FailedIngests
  for the non-fatal failures recorded under the run's `Context.run_id`,
  calls the provided retry function on each, and loops until clean or max
  sweeps reached. Failures recorded by other runs of the same source are
  never touched, so concurrent sweeps cannot retry the same row.

  The `retry_fn` argument is a 1-arity function that accepts a %FailedIngest{}
  and returns {:ok, :retried} | {:error, any()}.

  Returns {resolved_count, remaining_count}.
  """
  @spec sweep(context(), fun(), [{:max_sweeps, integer()}]) :: {integer(), integer()}
  def sweep(%Context{} = ctx, retry_fn, opts \\ []) do
    max_sweeps = Keyword.get(opts, :max_sweeps, 2)
    do_sweep(ctx, retry_fn, max_sweeps, 0)
  end

  defp do_sweep(%Context{run_id: run_id}, _retry_fn, 0, total_resolved) do
    remaining = length(Cake.FailedIngests.list_failed_ingests_for_run(run_id))

    {total_resolved, remaining}
  end

  defp do_sweep(%Context{run_id: run_id} = ctx, retry_fn, sweeps_left, total_resolved) do
    failures = Cake.FailedIngests.list_failed_ingests_for_run(run_id)

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
        {total_resolved, length(failures)}
      else
        do_sweep(ctx, retry_fn, sweeps_left - 1, total_resolved + resolved_this_sweep)
      end
    end
  end

  @doc """
  Counts the non-fatal `FailedIngest` rows recorded by one pipeline run,
  keyed on the run's `Context.run_id`. Rows from other runs of the same
  behaviour, implementation, and version are excluded, so the count is
  exact even when runs overlap. (Only non-fatal item failures are created
  inside a successful `with` chain; fatal failures short-circuit to
  `handle_ingest_error/2`.)
  """
  @spec count_failures(context()) :: non_neg_integer()
  def count_failures(%Context{run_id: run_id}) do
    run_id
    |> Cake.FailedIngests.list_failed_ingests_for_run()
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
  made it through, counts this run's item failures via `count_failures/1`,
  and builds the honest result via `summarize_ingest/3`.
  """
  @spec finalize_ingest(Enumerable.t(), context(), String.t()) ::
          {:ok, ingest_summary()} | {:error, {:no_items_ingested, ingest_summary()}}
  def finalize_ingest(indexed_stream, %Context{} = ctx, message) do
    indexed = Enum.count(indexed_stream)
    summarize_ingest(message, indexed, count_failures(ctx))
  end

  @spec build_context(atom(), atom(), String.t() | {integer(), integer(), integer()}, keyword()) ::
          context()
  def build_context(behaviour_module, source_pipeline, version, opts \\ [])

  @spec build_context(atom(), atom(), {integer(), integer(), integer()}) :: context()
  def build_context(behaviour_module, source_pipeline, {major, minor, patch}, opts) do
    version = Enum.join([major, minor, patch], ".")

    %Pipelines.Context{
      run_id: Ecto.UUID.generate(),
      behaviour: inspect(behaviour_module),
      implementation: inspect(source_pipeline),
      version: version,
      opts: opts
    }
  end

  @spec build_context(atom(), atom(), String.t()) :: context()
  def build_context(behaviour_module, source_pipeline, version, opts) do
    %Pipelines.Context{
      run_id: Ecto.UUID.generate(),
      behaviour: inspect(behaviour_module),
      implementation: inspect(source_pipeline),
      version: version,
      opts: opts
    }
  end

  @spec handle_ingest_error({:error, any()} | {:error, atom(), any()}, context()) ::
          {:error, {atom(), any()}} | {:error, any()}
  def handle_ingest_error({:error, step, error}, ctx) when is_atom(step) do
    Logger.warning("[#{ctx.behaviour}] Pipeline-fatal error at #{step}: #{inspect(error)}")

    _ =
      %{
        run_id: ctx.run_id,
        pipeline_behaviour: ctx.behaviour,
        pipeline_implementation: ctx.implementation,
        step: Atom.to_string(step),
        version: ctx.version,
        error_text: inspect(error),
        input_identifier: "",
        pipeline_fatal: true
      }
      |> Cake.FailedIngests.create_failed_ingest()
      |> log_rejected_failure(Atom.to_string(step), nil)

    {:error, {step, error}}
  end

  def handle_ingest_error({:error, error}, ctx) do
    Logger.warning("[#{ctx.behaviour}] Pipeline-fatal error: #{inspect(error)}")

    _ =
      %{
        run_id: ctx.run_id,
        pipeline_behaviour: ctx.behaviour,
        pipeline_implementation: ctx.implementation,
        step: "ingest",
        version: ctx.version,
        error_text: inspect(error),
        input_identifier: "",
        pipeline_fatal: true
      }
      |> Cake.FailedIngests.create_failed_ingest()
      |> log_rejected_failure("ingest", nil)

    {:error, error}
  end
end
