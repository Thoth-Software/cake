defmodule Cake.Conversation do
  use GenServer

  alias Cake.Books
  alias Cake.Embeddings

  require Logger

  @spec child_spec(map()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(opts) when is_map(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec start(map()) :: GenServer.on_start()
  def start(opts) when is_map(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      cluster: opts.cluster,
      reply_to: opts.reply_to,
      embedder: opts.embedder,
      index: opts.index,
      response_model: opts.response_model,
      provider: opts.provider,
      search_type: opts.search_type,
      fields: opts.fields,
      search_results: [],
      message_history: [],
      chunk_map: %{},
      citations: [],
      errors: []
    }

    {:ok, state}
  end

  @spec ask(pid(), String.t()) :: :ok
  def ask(pid, question) do
    GenServer.cast(pid, {:question, question})
  end

  # First turn: no search results yet — embed, search, then query LLM
  @impl GenServer
  def handle_cast({:question, question}, %{search_results: []} = state) do
    %{
      cluster: cluster,
      embedder: embedding_model,
      index: index,
      response_model: response_model,
      provider: provider,
      search_type: search_type,
      fields: fields
    } = state

    keyword_weight = 0.8

    with {:ok, %{attrs: %{embedding: embedding}}} <-
           Embeddings.embed(provider, %{input: question}, embedding_model),
         {:ok, %{hits: hits}} <-
           cluster.search(search_type, index, %{
             keywords: question,
             embedding: embedding,
             keyword_weight: keyword_weight,
             fields: fields
           }),
         chunks = Books.chunks_for_hits(hits),
         expanded_chunks = Books.expand_with_neighbors(chunks, 2),
         {:ok, %{response: response, chunk_map: chunk_map}} <-
           Cake.Responses.query_llm(:openai, expanded_chunks, question, response_model) do
      citations = Cake.Citations.extract(response, chunk_map)

      send(state.reply_to, {:convo_response, response, citations})

      {:noreply,
       %{
         state
         | search_results: expanded_chunks,
           message_history: [question, response],
           chunk_map: chunk_map,
           citations: citations
       }}
    else
      {:error, error} ->
        send(state.reply_to, {:convo_error, error})
        {:noreply, %{state | errors: [error | state.errors]}}
    end
  end

  # Subsequent turns: search results already populated — skip search, continue conversation
  @impl GenServer
  def handle_cast({:question, question}, %{search_results: search_results} = state) do
    with {:ok, %{response: response, chunk_map: chunk_map}} <-
           Cake.Responses.query_llm(:openai, search_results, question, state.response_model) do
      citations = Cake.Citations.extract(response, chunk_map)

      send(state.reply_to, {:convo_response, response, citations})

      {:noreply,
       %{
         state
         | message_history: state.message_history ++ [question, response],
           chunk_map: chunk_map,
           citations: citations
       }}
    else
      {:error, error} ->
        send(state.reply_to, {:convo_error, error})
        {:noreply, %{state | errors: [error | state.errors]}}
    end
  end

  @impl GenServer
  def handle_call(:search_results, {from, _}, %{search_results: chunks} = state)
      when is_list(chunks) and chunks != [] do
    Logger.debug(
      "search_results requested by #{inspect(from)}, returning #{length(chunks)} chunks"
    )

    {:reply, chunks, state}
  end

  @impl GenServer
  def handle_call(:search_results, {_from, _}, %{search_results: []} = state) do
    Logger.debug("search_results requested but none available yet")
    {:reply, [], state}
  end

  @impl GenServer
  def handle_call(:chunk_map, _from, %{chunk_map: chunk_map} = state) do
    {:reply, chunk_map, state}
  end

  @impl GenServer
  def handle_call(:citations, _from, %{citations: citations} = state) do
    {:reply, citations, state}
  end

  @impl GenServer
  def handle_call(:inspect, _from, state) do
    {:reply, state, state}
  end

  @spec print_hierarchy(map(), list()) :: list()
  def print_hierarchy(map, prefix \\ []) do
    for {key, value} <- map do
      IO.puts("#{Enum.join(prefix, ".")}#{key}")

      if is_map(value) do
        print_hierarchy(value, prefix ++ [key])
      end
    end
  end
end
