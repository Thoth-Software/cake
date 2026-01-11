defmodule Caque.Pipelines do
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
      |> detuple()
    end
  end

  defp skip_opensearch? do
    Application.get_env(:caque, :skip_opensearch, false)
  end

  # NOTE: We need to put together moduledocs for these instead of comments
  # The {:exit, element} tuple is emitted when the process spawned by task.asyn_stream dies
  defp handle_opensearch_response({:exit, element}),
    do: Logger.warning("Failed to insert document #{element.id}. Process died")

  defp handle_opensearch_response({:ok, task_response}),
    do: handle_opensearch_response(task_response)

  defp handle_opensearch_response({:error, changeset}),
    do: Logger.warning("Could not insert document. Changeset: #{inspect(changeset)}")

  defp handle_opensearch_response(%{"_id" => id}),
    do: Logger.info("Document #{id} created")

  def detuple(stream_enumerable) do
    stream_enumerable
    |> Stream.filter(fn
      {:ok, _} -> true
      _ -> false
    end)
    |> Stream.map(fn {:ok, value} -> value end)
  end
end
