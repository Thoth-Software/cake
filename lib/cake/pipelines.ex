defmodule Cake.Pipelines do
  @moduledoc """
  Various assorted motley helpers, doohickeys, and dongles for data ingestion pipelines. Some of this may very well be cruft.
  """

  require Logger

  def add_to_opensearch(docs_with_embeddings_stream, index, cluster) do
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
      |> detuple_with_logging("opensearch.index")
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

  defp handle_opensearch_task_result({:error, error}),
    do: {:error, {:opensearch_api_error, error}}

  defp handle_opensearch_task_result(%{"_id" => id}) do
    Logger.info("Document #{id} created")
    {:ok, id}
  end

  @doc """
  Filters a stream of {:ok, value} | {:error, reason} tuples,
  logging errors and passing through successes.

  The `step_name` parameter identifies which pipeline stage failed,
  for log readability.
  """
  # TODO: Persist errors to a dedicated table for retry (point 5)
  # TODO: Return a summary of {success_count, error_count} after Stream.run (point 4)
  def detuple_with_logging(stream_enumerable, step_name) do
    stream_enumerable
    |> Stream.filter(fn
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.warning("[#{step_name}] Item failed: #{inspect(reason)}")
        false

      other ->
        Logger.warning("[#{step_name}] Unexpected value: #{inspect(other)}")
        false
    end)
    |> Stream.map(fn {:ok, value} -> value end)
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
