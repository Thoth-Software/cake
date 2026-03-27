defmodule Cake.Conversation do
  use GenServer

  alias Cake.Embeddings
  require Logger

  # Eventually, Cake.Documents.Cluster will be replaced by something
  # configurable. The idea there is to make this conversation module be agnostic
  # about clusters and just manage conversations, and be able to do so for
  # arbitrary clusters.

  # External API (Client Functions)
  # 
  # For now, the external API assumes that the caller process will track
  # conversation PIDs. This is sufficient up to MVP. However, once we reach MVP
  # and need to implement supervision trees and state recovery, we'll want a
  # registry. The change-over to a registry implies changes to caller processes,
  # i.e. they will simplify.
  #
  # Also note that the external API has an implicit contract. The arguments to
  # GenServer.cast are `pid`, `caller`, and `{:type_of_request, request_contents}`. The
  # external API exposes functions that designate a request type, so
  # :type_of_request is not part of the external API, just `request_contents`.
  # `pid` and `caller`, however, ARE part of the external API because the caller process is
  # assumed to track that. Once we switch to registries for processes, `pid`
  # will drop out. Also, one of our stretch goals is for the user to specify
  # what kind of search they want (vector/keyword/hybrid), so in addition to
  # :type_of_request, the tuple passed to `GenServer.cast` will also contain
  # `:search_type` and `type`. `type` will also be part of the external API, but
  # will default to `hybrid` so the caller only has to think about `search_type`
  # if it really wants to
  #
  # Eventually, the start_link clause will expect a `Conversation` struct. For now, just a map is fine. 
  # caller: params.caller,
  # embedder: params.embedder,
  # index: params.index,
  # llm: params.llm,
  # provider: params.provider,
  # search_type: params.search_type

  def start_link(caller, embedder, index, response_model, provider, search_type) do
    params = %{
      caller: caller,
      embedder: embedder,
      index: index,
      response_model: response_model,
      provider: provider,
      search_type: search_type
    }

    state = %{
      params: params,
      search_results: [],
      message_history: [],
      chunk_map: %{},
      citations: [],
      errors: []
    }

    GenServer.start_link(__MODULE__, state)
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  # {:ok, pid} = Cake.Conversation.start_link(Cake.Documents.Cluster,"text-embedding-ada-002", "docs", "gpt-5", :openai, :hybrid)
  # Cake.Conversation.ask(pid, "Which Elixir function would I use to spin up a short-lived process to do a job and then die?")
  def ask(pid, question) do
    GenServer.cast(pid, {:question, question})
  end

  @impl true
  def handle_cast(
        {:question, question},
        %{
          search_results: [],
          params: %{
            caller: caller,
            embedder: embedding_model,
            index: index,
            response_model: response_model,
            provider: provider,
            search_type: search_type
          }
        } =
          state
      ) do
    with {:ok, %{attrs: %{embedding: embedding}}} <-
           Embeddings.embed(provider, question, embedding_model),
         {:ok, %{hits: hits}} <-
           caller.search(search_type, index, %{
             keywords: question,
             embedding: embedding,
             keyword_weight: 0.5
           }),
         {:ok, %{response: response, chunk_map: chunk_map}} <-
           Cake.Responses.query_llm(:openai, hits, question, response_model) do
      citations = Cake.Citations.extract(response, chunk_map)
      convo_state = %{search_results: hits, message_history: [question, response], chunk_map: chunk_map, citations: citations}

      {:noreply, Map.merge(state, convo_state)}
    else
      # Fix this because the error variable here contains a whole-ass error tuple anyway. Right now one of these functions (I think it's vector_search/2 in Documents.Cluster) is responsible for that. Fix ya shit.
      {:error, error} ->
        errors = %{errors: [error | state.errors]}
        {:noreply, Map.merge(state, errors)}
    end
  end

  @impl true
  def handle_cast(
        {:question, question},
        %{
          search_results: search_results,
          message_history: message_history,
          params: %{response_model: response_model}
        } = state
      ) do
    convo_state =
      with {:ok, %{response: response, chunk_map: chunk_map}} <-
             Cake.Responses.query_llm(:openai, search_results, question, response_model) do
        citations = Cake.Citations.extract(response, chunk_map)

        %{
          search_results: search_results,
          message_history: message_history ++ [question, response],
          chunk_map: chunk_map,
          citations: citations
        }
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
  def handle_call(:search_results, {from, _}, %{search_results: hits} = state) when is_list(hits) and hits != [] do
    Logger.info("WHOOP MAH NAME IS CHICKA CHICKA #{inspect(from)}")

    search_results =
      Enum.map(hits, fn %{source: source} ->
        Map.take(source, ["language", "package", "source", "title", "text", "url", "version"])
      end)

    {:reply, search_results, state}
  end

  @impl true
  def handle_call(:search_results, {_from, _}, %{search_results: []} = state) do
    Logger.info("AWWW HELL NAH NO SEARCH RESULTS YET DAWG")

    {:reply, [], state}
  end

  @impl true
  def handle_call(:chunk_map, _from, %{chunk_map: chunk_map} = state) do
    {:reply, chunk_map, state}
  end

  @impl true
  def handle_call(:citations, _from, %{citations: citations} = state) do
    {:reply, citations, state}
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
