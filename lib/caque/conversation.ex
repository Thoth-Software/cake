defmodule Caque.Conversation do
  use GenServer

  alias Caque.Documents.ParsedDocument
  alias Caque.Embeddings
  require Logger

  # Eventually, Caque.Documents.Cluster will be replaced by something
  # configurable. The idea there is to make this conversation module be agnostic
  # about clusters and just manage conversations, and be able to do so for
  # arbitrary clusters.

  # Callbacks

  # GenServer.start(Caque.Conversation, %{automatic: true})
  @impl true
  def init(%{automatic: true} = params) do
    {:ok, %{params: params, search_results: [], message_history: [], errors: []}}
  end

  # {:ok, pid} = GenServer.start_link(Caque.Conversation, %{automatic: true})
  # GenServer.cast(pid, {:question, "What Elixir function starts a process?"})
  @impl true
  def handle_cast({:question, question}, %{search_results: []} = state) do
    embedding_model = "text-embedding-ada-002"
    completion_model = "gpt-5"
    doc = %ParsedDocument{text: question, title: ""}

    convo_state =
      with {:ok, %{attrs: %{embedding: embedding}}} <-
             Embeddings.embed(:openai, doc, embedding_model),
           {:ok, %{hits: hits}} <- Caque.Documents.Cluster.vector_search("docs", embedding),
           {:ok, %{completion: completion}} <-
             Caque.Completions.complete(:openai, hits, question, completion_model) do
               %{search_results: hits, message_history: [question, completion]}
               else
                   # Fix this because the error variable here contains a whole-ass error tuple anyway. Right now one of these functions (I think it's vector_search/2 in Documents.Cluster) is responsible for that. Fix ya shit.
                 {:error, error} -> %{errors: %{errors: [error | state.errors]}}
      end


    {:noreply, Map.merge(state, convo_state)}
  end

  @impl true
  def handle_cast({:question, question}, %{search_results: search_results, message_history: message_history} = state) do
    completion_model = "gpt-5"

    convo_state =
      with {:ok, %{completion: completion}} <- Caque.Completions.complete(:openai, search_results, question, completion_model) do
               %{search_results: search_results, message_history: message_history ++ [question, completion]}
               else
                 {:error, error} -> %{errors: [error | state.errors]}
      end


    {:noreply, Map.merge(state, convo_state)}
  end

  @impl true
  def handle_cast(_msg, state) do
    dbg(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:search_results, {from, _}, %{search_results: %{hits: hits}} = state) do
    Logger.info("WHOOP MAH NAME IS CHICKA CHICKA #{inspect(from)}")

    search_results =
    Enum.map(hits, fn %{source: source} ->
      Map.take(source, ["language", "package", "source", "title", "text", "url", "version"])
    end)

    {:reply, search_results, state}
  end

  @impl true
  def handle_call(:search_results, {from, _}, %{search_results: []} = state) do
    Logger.info("AWWW HELL NAH NO SEARCH RESULTS YET DAWG")

    {:reply, [], state}
  end

  def print_hierarchy(map, prefix \\ []) do
    for {key, value} <- map do
      IO.puts("#{Enum.join(prefix, ".")}#{key}")

      if is_map(value) do
        print_hierarchy(value, prefix ++ [key])
      end
    end
  end
end
