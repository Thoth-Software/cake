defmodule Cake.Conversation do
  @moduledoc """
  Conversation orchestrator: the sole module that composes the turn pipeline.

  ## State machine

      :idle --{:autoask, q}-->       :generating        --> :idle
      :idle --{:manualask, q}-->     :awaiting_selection
      :awaiting_selection --{:select, ids}--> :generating --> :idle

  Invalid transitions crash the GenServer (no defensive clauses; the UI
  is expected to prevent invalid messages).

  ## Pipelines

  - `run_turn/2` — full auto-mode pipeline (search → select → prompt →
    generate → cite).
  - `run_manual_turn/4` — manual-mode back-half (apply_selection → prompt →
    generate → cite) after user picks documents.

  Stages are `@doc false` public functions for direct testability.

  ## Dependencies

  Search, embeddings, generation, and responses modules are passed as opts at
  `start_link/1` time to support Mox-based testing.

  ## Broadcasts

  See `Cake.Conversation.Events` for event shapes emitted on the
  `"conversation:\#{id}"` topic.
  """

  use GenServer

  alias Cake.Conversation.Events
  alias Cake.Conversation.State
  alias Cake.Search.Result

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
      embedder: opts.embedder,
      response_model: opts.response_model,
      provider: opts.provider,
      embeddings: Map.get(opts, :embeddings, Cake.Embeddings),
      responses: Map.get(opts, :responses, Cake.Responses),
      generation: Map.get(opts, :generation, Cake.Generation.OpenAI),
      gds: opts.gds
    }
  end

  @spec autoask(pid(), String.t()) :: :ok
  def autoask(pid, question) do
    GenServer.cast(pid, {:autoask, question})
  end

  @impl GenServer
  def handle_cast({:autoask, question}, %State{state: :idle} = s) do
    do_auto_turn(question, s)
  end

  defp do_auto_turn(question, %State{} = s) do
    _ = broadcast(s, {:state_change, :generating})

    case run_turn(question, s) do
      {:ok, {response, citations, new_state}} ->
        _ = emit_response(s, response, citations)
        {:noreply, new_state}

      {:error, error} ->
        _ = emit_error(s, error)
        {:noreply, %{s | errors: [error | s.errors]}}
    end
  end

  # --- Manual mode ---

  @spec manualask(pid(), String.t()) :: {:ok, [Result.t()]} | {:error, term()}
  def manualask(pid, question) do
    GenServer.call(pid, {:manualask, question})
  end

  @spec select_docs(pid(), [String.t()]) :: :ok | {:error, term()}
  def select_docs(pid, doc_ids) do
    GenServer.call(pid, {:select, doc_ids})
  end

  # --- Auto-mode turn pipeline ---

  defp run_turn(question, %State{} = s) do
    with {:ok, scored_results} <- resolve_search_results(question, s),
         {:ok, indexed_chunks} <- select(scored_results),
         {:ok, messages} <- build_prompt(indexed_chunks, question, s.message_history),
         {:ok, response} <- generate(messages, s),
         {:ok, result} <- process_response(response, indexed_chunks, s) do
      finalize_turn(s, scored_results, question, response, result)
    end
  end

  # --- Manual-mode turn pipeline ---

  defp run_manual_turn(question, candidates, doc_ids, %State{} = s) do
    with {:ok, indexed_chunks} <- apply_selection(candidates, doc_ids),
         {:ok, messages} <- build_prompt(indexed_chunks, question, s.message_history),
         {:ok, response} <- generate(messages, s),
         {:ok, result} <- process_response(response, indexed_chunks, s) do
      finalize_turn(s, candidates, question, response, result)
    end
  end

  defp finalize_turn(%State{} = s, scored_results, question, response, result) do
    new_state = update_state(s, scored_results, question, response, result)
    {:ok, {result.final_text, result.citations, new_state}}
  end

  # --- Stage 0: resolve search results (search on first turn, reuse on subsequent) ---

  @doc false
  @spec resolve_search_results(String.t(), State.t()) ::
          {:ok, [Result.t()]} | {:error, term()}
  def resolve_search_results(_question, %State{search_results: results}) when results != [] do
    {:ok, results}
  end

  def resolve_search_results(question, %State{} = s) do
    embed_and_search(question, s)
  end

  # --- Stage 1a: apply_selection (manual mode) ---

  @doc false
  @spec apply_selection([Result.t()], [String.t()]) ::
          {:ok, [Cake.Prompt.indexed_chunk()]} | {:error, term()}
  def apply_selection(candidates, doc_ids) do
    available_ids =
      MapSet.new(candidates, fn %Result{retrieval_unit: unit} ->
        Cake.Citable.metadata(unit).id
      end)

    requested = MapSet.new(doc_ids)
    unknown = MapSet.difference(requested, available_ids)

    if MapSet.size(unknown) > 0 do
      {:error, {:unknown_doc_ids, MapSet.to_list(unknown)}}
    else
      selected =
        candidates
        |> Enum.filter(fn %Result{retrieval_unit: unit} ->
          Cake.Citable.metadata(unit).id in doc_ids
        end)
        |> Enum.with_index(1)
        |> Enum.map(fn {result, idx} -> {idx, result} end)

      {:ok, selected}
    end
  end

  # --- Stage 1b: select (auto mode) ---

  @doc false
  @spec select([Result.t()]) :: {:ok, [Cake.Prompt.indexed_chunk()]}
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
    case s.generation.complete(messages, s.response_model, []) do
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
         {:ok, raw_results} <-
           s.search.search_chunks_with_context(
             :hybrid,
             question,
             embedding,
             Cake.Search.OpenSearch.default_expand_offset(),
             gds: s.gds
           ) do
      scored_results =
        raw_results
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
    scores = Enum.map(scored_results, & &1.relevance_score)
    {Enum.min(scores, fn -> 0.0 end), Enum.max(scores, fn -> 0.0 end)}
  end

  # --- Manual-mode handlers ---

  @impl GenServer
  def handle_call({:manualask, question}, _from, %State{state: :idle} = s) do
    case embed_and_search(question, s) do
      {:ok, candidates} ->
        pending = %{question: question, candidates: candidates}
        new_state = %{s | state: :awaiting_selection, pending: pending}
        _ = broadcast(s, {:candidates_ready, candidates})
        _ = broadcast(s, {:state_change, :awaiting_selection})
        {:reply, {:ok, candidates}, new_state}

      {:error, _} = error ->
        _ = broadcast(s, {:error, elem(error, 1)})
        {:reply, error, s}
    end
  end

  @impl GenServer
  def handle_call({:select, doc_ids}, _from, %State{state: :awaiting_selection} = s) do
    %{question: question, candidates: candidates} = s.pending
    _ = broadcast(s, {:state_change, :generating})

    case run_manual_turn(question, candidates, doc_ids, s) do
      {:ok, {response, citations, new_state}} ->
        new_state = %{new_state | state: :idle, pending: nil}
        _ = emit_response(s, response, citations)
        {:reply, :ok, new_state}

      {:error, error} ->
        new_state = %{s | state: :idle, pending: nil, errors: [error | s.errors]}
        _ = emit_error(s, error)
        {:reply, {:error, error}, new_state}
    end
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

  defp emit_response(%State{} = s, response, citations) do
    _ = broadcast(s, {:response_ready, %{response: response, citations: citations}})
    broadcast(s, {:state_change, :idle})
  end

  defp emit_error(%State{} = s, error) do
    _ = broadcast(s, {:error, error})
    broadcast(s, {:state_change, :idle})
  end

  defp broadcast(%State{id: id}, event) do
    Phoenix.PubSub.broadcast(Cake.PubSub, Events.topic(id), event)
  end
end
