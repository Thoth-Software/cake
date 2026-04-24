defmodule Cake.Conversation do
  @moduledoc """
  Conversation orchestrator: the sole module that composes the turn pipeline.

  ## Turn pipeline

  A turn executes the following stages in order via `run_turn/2`:

    1. `resolve_search_results/2` — retrieve or reuse scored chunks
    2. `select/1`                 — filter by relevance, assign 1..N indices
    3. `build_prompt/3`           — assemble the LLM message list
    4. `generate/2`               — invoke the LLM
    5. `process_response/3`       — citation resolution, renumbering, formatting

  The pipeline is called from `handle_cast({:question, _}, _)`. Stages are
  `@doc false` public functions for direct testability; they are not intended
  for use outside this module.

  ## Dependencies

  Search, embeddings, generation, and responses modules are passed as opts at
  `start_link/1` time to support Mox-based testing.
  """

  use GenServer

  alias Cake.Conversation.State

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
    with {:ok, _id} <- fetch_required(opts, :id),
         {:ok, _gds} <- fetch_required(opts, :gds) do
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @spec start(map()) :: GenServer.on_start()
  def start(opts) when is_map(opts) do
    with {:ok, _id} <- fetch_required(opts, :id),
         {:ok, _gds} <- fetch_required(opts, :gds) do
      GenServer.start(__MODULE__, opts)
    end
  end

  @impl GenServer
  def init(opts) do
    {:ok, build_state(opts)}
  end

  defp fetch_required(opts, key) do
    case Map.fetch(opts, key) do
      {:ok, nil} -> {:error, %KeyError{key: key, term: opts}}
      {:ok, value} -> {:ok, value}
      :error -> {:error, %KeyError{key: key, term: opts}}
    end
  end

  defp build_state(opts) do
    %State{
      id: opts.id,
      search: opts.search,
      reply_to: opts.reply_to,
      embedder: opts.embedder,
      response_model: opts.response_model,
      provider: opts.provider,
      embeddings: Map.get(opts, :embeddings, Cake.Embeddings),
      responses: Map.get(opts, :responses, Cake.Responses),
      generation: Map.get(opts, :generation, Cake.Generation.OpenAI),
      gds: opts.gds
    }
  end

  @spec ask(pid(), String.t()) :: :ok
  def ask(pid, question) do
    GenServer.cast(pid, {:question, question})
  end

  @impl GenServer
  def handle_cast({:question, question}, %State{state: :idle} = s) do
    case run_turn(question, s) do
      {:ok, {response, citations, new_state}} ->
        send(s.reply_to, {:convo_response, response, citations})
        {:noreply, new_state}

      {:error, error} ->
        send(s.reply_to, {:convo_error, error})
        {:noreply, %{s | errors: [error | s.errors]}}
    end
  end

  # --- Turn pipeline ---

  defp run_turn(question, %State{} = s) do
    with {:ok, scored_results} <- resolve_search_results(question, s),
         {:ok, indexed_chunks} <- select(scored_results),
         {:ok, messages} <- build_prompt(indexed_chunks, question, s.message_history),
         {:ok, response} <- generate(messages, s),
         {:ok, result} <- process_response(response, indexed_chunks, s) do
      finalize_turn(s, scored_results, question, response, result)
    end
  end

  defp finalize_turn(%State{} = s, scored_results, question, response, result) do
    new_state = update_state(s, scored_results, question, response, result)
    {:ok, {result.final_text, result.citations, new_state}}
  end

  # --- Stage 0: resolve search results (search on first turn, reuse on subsequent) ---

  @doc false
  @spec resolve_search_results(String.t(), State.t()) ::
          {:ok, [Cake.Search.scored_result()]} | {:error, term()}
  def resolve_search_results(_question, %State{search_results: results}) when results != [] do
    {:ok, results}
  end

  def resolve_search_results(question, %State{} = s) do
    embed_and_search(question, s)
  end

  # --- Stage 1: select ---

  @doc false
  @spec select([Cake.Search.scored_result()]) :: {:ok, [Cake.Prompt.indexed_chunk()]}
  def select(scored_results) do
    {indexed_chunks, _context_quality} = Cake.Prompt.prepare_context(scored_results)
    {:ok, indexed_chunks}
  end

  # --- Stage 2: prompt ---

  @doc false
  @spec build_prompt([Cake.Prompt.indexed_chunk()], String.t(), [String.t()]) ::
          {:ok, [Cake.Prompt.message()]}
  def build_prompt(indexed_chunks, question, history) do
    {:ok, Cake.Prompt.build(indexed_chunks, question, history)}
  end

  # --- Stage 3: generate ---

  @doc false
  @spec generate([Cake.Prompt.message()], State.t()) ::
          {:ok, String.t()} | {:error, term()}
  def generate(messages, %State{} = s) do
    case s.generation.complete(messages, s.response_model) do
      {:ok, %{text: response, usage: _usage}} -> {:ok, response}
      {:error, _} = error -> error
    end
  end

  # --- Stage 4: process response (cite) ---

  @doc false
  @spec process_response(String.t(), [Cake.Prompt.indexed_chunk()], State.t()) ::
          {:ok, Cake.Responses.Result.t()}
  def process_response(response, indexed_chunks, %State{} = s) do
    {:ok, s.responses.process(response, indexed_chunks, [])}
  end

  # --- State update ---

  defp update_state(%State{} = s, scored_results, question, response, result) do
    history =
      case s.search_results do
        [] -> [question, response]
        _ -> s.message_history ++ [question, response]
      end

    %{
      s
      | search_results: scored_results,
        message_history: history,
        chunk_map: result.chunk_map,
        citations: result.citations
    }
  end

  # --- Search internals ---

  defp embed_and_search(question, %State{} = s) do
    with {:ok, %{attrs: %{embedding: embedding}}} <-
           s.embeddings.embed(s.provider, %{input: question}, s.embedder),
         {:ok, scored_hits} <-
           s.search.search_chunks_with_context(
             :hybrid,
             question,
             embedding,
             Cake.Search.OpenSearch.default_expand_offset(),
             gds: s.gds
           ) do
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

  # --- Read-only accessors ---

  @impl GenServer
  def handle_call(:search_results, {from, _}, %State{search_results: chunks} = s)
      when is_list(chunks) and chunks != [] do
    Logger.debug(
      "search_results requested by #{inspect(from)}, returning #{length(chunks)} chunks"
    )

    {:reply, chunks, s}
  end

  @impl GenServer
  def handle_call(:search_results, {_from, _}, %State{search_results: []} = s) do
    Logger.debug("search_results requested but none available yet")
    {:reply, [], s}
  end

  @impl GenServer
  def handle_call(:chunk_map, _from, %State{chunk_map: chunk_map} = s) do
    {:reply, chunk_map, s}
  end

  @impl GenServer
  def handle_call(:citations, _from, %State{citations: citations} = s) do
    {:reply, citations, s}
  end

  @impl GenServer
  def handle_call(:inspect, _from, %State{} = s) do
    {:reply, s, s}
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
