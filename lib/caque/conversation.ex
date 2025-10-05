defmodule Caque.Conversation do
  use GenServer

  @workflow_path "/_plugins/_flow_framework/workflow?use_case=conversational_search_with_llm_deploy&provision=true"

  # Eventually, Caque.Documents.Cluster will be replaced by something
  # configurable. The idea there is to make this conversation module be agnostic
  # about clusters and just manage conversations, and be able to do so for
  # arbitrary clusters.

  # Callbacks

  # GenServer.start(Caque.Conversation, %{automatic: true})
  @impl true
  def init(%{automatic: true} = params) do
    # We defer all HTTP requests and blocking operations to handle_continue/2
    # because init/1 must return quickly to avoid blocking the supervision tree.
    # Performing network calls, polling, or other slow operations here would
    # prevent the GenServer from starting and could hang the entire application
    # startup sequence.
    {:ok, %{params: params}, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, %{params: params} = state) do
    openai_key = Application.get_env(:caque, Caque.Embeddings)[:openai_key]

    # Create workflow
    workflow_payload = %{"create_connector.credential.key" => openai_key}

    {:ok, %{"workflow_id" => workflow_id}} =
      Snap.post(Caque.Documents.Cluster, @workflow_path, workflow_payload)

    # Poll workflow status until COMPLETED
    poll_until_completed(workflow_id)

    # Get workflow resources to extract the search pipeline name
    {:ok, workflow_status} = Snap.get(Caque.Documents.Cluster, "/_plugins/_flow_framework/workflow/#{workflow_id}/_status")
    dbg(workflow_status)
    search_pipeline = extract_search_pipeline(workflow_status)

    # Create conversation memory
    memory_path = "/_plugins/_ml/memory/"
    memory_payload = %{"name" => "hexdocs convo"}
    {:ok, %{"memory_id" => memory_id}} = Snap.post(Caque.Documents.Cluster, memory_path, memory_payload)

    {:noreply, Map.merge(state, %{
      workflow_id: workflow_id,
      memory_id: memory_id,
      search_pipeline: search_pipeline,
      params: params
    })}
  end

  def get_messages(memory_id) do
    message_path = "/_plugins/_ml/memory/#{memory_id}/messages"
    Snap.get(Caque.Documents.Cluster, message_path)
    |> dbg()
  end


# Snap.Search.search(cluster, index_or_alias, query, params \\ [], headers \\ [], opts \\ [])

  # {:ok, pid} = GenServer.start_link(Caque.Conversation, %{automatic: true})
  # GenServer.cast(pid, {:question, "What Elixir function starts a process?"})
  @impl true
  def handle_cast({:question, question}, %{memory_id: memory_id} = state) do
    # Send question to OpenSearch conversational RAG endpoint
    message_path = "/_plugins/_ml/memory/#{memory_id}/messages"
    message_payload = %{"input" => question}

    response = Snap.post(Caque.Documents.Cluster, message_path, message_payload)
    |> dbg()

    case response do
      {:ok, _} ->
        IO.inspect(response, label: "Conversation response")

      {:error, error} ->
        IO.inspect(error, label: "Conversation error")
    end

    dbg(state)
    {:noreply, state}
  end

  defp poll_until_completed(workflow_id) do
    status_path = "/_plugins/_flow_framework/workflow/#{workflow_id}/_status"
    case Snap.get(Caque.Documents.Cluster, status_path) do
      {:ok, %{"state" => "COMPLETED"}} ->
        :ok

      {:ok, %{"state" => _other_state}} ->
        Process.sleep(1000)
        poll_until_completed(workflow_id)

      {:error, reason} ->
        raise "#{inspect(reason)}"
    end
  end

  defp extract_search_pipeline(%{"resources_created" => resources}) do
    resources
    |> Enum.find_value(fn
      %{"resource_id" => pipeline_id, "resource_type" => "pipeline_id"} -> pipeline_id
      _ -> nil
    end)
  end

  defp extract_search_pipeline(_), do: nil
end
