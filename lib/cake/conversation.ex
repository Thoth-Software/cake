defmodule Cake.Conversation do
  use GenServer

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
      search: opts.search,
      reply_to: opts.reply_to,
      embedder: opts.embedder,
      response_model: opts.response_model,
      provider: opts.provider,
      responses: Map.get(opts, :responses, Cake.Responses),
      generation: Map.get(opts, :generation, Cake.Generation.OpenAI),
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
    case run_first_turn(question, state) do
      {:ok, {response, citations, new_state}} ->
        send(state.reply_to, {:convo_response, response, citations})
        {:noreply, new_state}

      {:error, error} ->
        send(state.reply_to, {:convo_error, error})
        {:noreply, %{state | errors: [error | state.errors]}}
    end
  end

  # Subsequent turns: search results already populated — skip search, continue conversation
  @impl GenServer
  def handle_cast({:question, question}, %{search_results: search_results} = state) do
    case run_subsequent_turn(question, search_results, state) do
      {:ok, {response, citations, new_state}} ->
        send(state.reply_to, {:convo_response, response, citations})
        {:noreply, new_state}

      {:error, error} ->
        send(state.reply_to, {:convo_error, error})
        {:noreply, %{state | errors: [error | state.errors]}}
    end
  end

  defp run_first_turn(question, state) do
    with {:ok, scored_results} <- embed_and_search(question, state) do
      {indexed_chunks, _context_quality} = Cake.Prompt.prepare_context(scored_results)
      messages = Cake.Prompt.build(indexed_chunks, question, [])

      case state.generation.complete(messages, state.response_model) do
        {:ok, %{text: response, usage: _usage}} ->
          result = state.responses.process(response, indexed_chunks, [])

          new_state = %{
            state
            | search_results: scored_results,
              message_history: [question, response],
              chunk_map: result.chunk_map,
              citations: result.citations
          }

          {:ok, {result.final_text, result.citations, new_state}}

        {:error, _} = error ->
          error
      end
    end
  end

  defp embed_and_search(question, state) do
    %{search: search, provider: provider, embedder: embedder} = state

    with {:ok, %{attrs: %{embedding: embedding}}} <-
           Embeddings.embed(provider, %{input: question}, embedder),
         {:ok, scored_hits} <-
           search.search_chunks_with_context(:hybrid, question, embedding) do
      scored_results =
        scored_hits
        |> Cake.Search.score_results(embedding)
        |> Cake.Search.normalize_and_combine()
        |> Cake.Search.sort_by_relevance()

      Logger.debug(
        "Scored #{length(scored_results)} results. " <>
          "Relevance range: #{inspect(score_range(scored_results))}"
      )

      {:ok, scored_results}
    end
  end

  defp score_range(scored_results) do
    scores = Enum.map(scored_results, fn {_, %{relevance_score: s}} -> s end)
    {Enum.min(scores, fn -> 0.0 end), Enum.max(scores, fn -> 0.0 end)}
  end

  defp run_subsequent_turn(question, scored_results, state) do
    {indexed_chunks, _context_quality} = Cake.Prompt.prepare_context(scored_results)
    messages = Cake.Prompt.build(indexed_chunks, question, state.message_history)

    case state.generation.complete(messages, state.response_model) do
      {:ok, %{text: response, usage: _usage}} ->
        result = state.responses.process(response, indexed_chunks, [])

        new_state = %{
          state
          | message_history: state.message_history ++ [question, response],
            chunk_map: result.chunk_map,
            citations: result.citations
        }

        {:ok, {result.final_text, result.citations, new_state}}

      {:error, _} = error ->
        error
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
      Logger.debug("#{Enum.join(Enum.reverse(prefix), ".")}#{key}")

      if is_map(value) do
        print_hierarchy(value, [key | prefix])
      end
    end
  end
end
