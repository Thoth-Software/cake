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

  - `run_turn/2` — full auto-mode pipeline (decompose → search → select →
    prompt → generate → cite), dispatching to the sequential pipeline when
    the decomposition strategy is `:sequential`.
  - `run_sequential_turn/3` — least-to-most back-half: resolve each
    sub-question in topological order (search → prompt with accumulated
    prior answers → intermediate answer), then synthesize the final answer
    over the merged context plus the accumulated answers.
  - `run_manual_turn/4` — manual-mode back-half (apply_selection → prompt →
    generate → cite) after user picks documents.

  Stages are `@doc false` public functions for direct testability.

  ## Query decomposition

  Opt-in via the `:decomposition` opt (a module implementing
  `Cake.Decomposition`; default `nil` — no decomposition). When set, the
  first turn's question is decomposed before searching: an atomic result
  searches the original question exactly as before, while a decomposed one
  runs one embed+search per sub-question and merges the deduplicated
  results into a single context. Each merged result's
  `Cake.Search.Provenance` is stamped with `decomposed: true`, the
  `original_query`, and its `sub_question_index`.

  A `:sequential` decomposition (entries with `depends_on` edges) instead
  resolves least-to-most: sub-questions run one at a time in topological
  order, each prompt carrying the accumulated prior question/answer pairs,
  budgeted by the `:max_context_tokens` opt (default from
  `config :cake, :decomposition_max_context_tokens, 4096`) with the oldest
  pairs evicted first. The final answer is generated over the merged,
  deduplicated context plus the surviving accumulated answers. Any
  intermediate search or generation error fails the whole turn.

  For `:flat` decompositions, sub-question searches fan out concurrently under `Cake.TaskSupervisor`,
  capped by `config :cake, :max_sub_search_concurrency` (default 4; set to
  1 to force sequential fan-out in constrained environments). Each
  sub-search must finish within `config :cake, :sub_search_timeout`
  (default 30s). Failure handling is all-or-nothing: any sub-search error,
  timeout (`:sub_search_timeout`), or crash
  (`{:sub_search_crashed, reason}`) fails the whole turn, reporting the
  lowest-index failure — there is no partial context.

  ## Dependencies

  Search, embeddings, generation, responses, and (optionally) decomposition
  modules are passed as opts at `start_link/1` time to support Mox-based
  testing.

  ## Broadcasts

  See `Cake.Conversation.Events` for event shapes emitted on the
  `"conversation:\#{id}"` topic.
  """

  use Boundary,
    top_level?: true,
    deps: [
      Cake,
      Cake.Decomposition,
      Cake.Embeddings,
      Cake.Generation,
      Cake.Prompt,
      Cake.Responses,
      Cake.Search
    ],
    exports: [Events]

  use GenServer

  alias Cake.Conversation.Events
  alias Cake.Conversation.State
  alias Cake.Search.Result

  require Logger

  @default_max_sub_search_concurrency 4
  @default_sub_search_timeout :timer.seconds(30)
  @default_max_context_tokens 4096

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

  @spec start(map()) :: DynamicSupervisor.on_start_child()
  def start(opts) when is_map(opts) do
    with {:ok, _id} <- fetch_required(opts, :id),
         {:ok, _gds} <- fetch_required(opts, :gds) do
      DynamicSupervisor.start_child(Cake.ConversationSupervisor, {__MODULE__, opts})
    end
  end

  @impl GenServer
  @spec init(map()) :: {:ok, State.t()}
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
      embedder: opts.embedder,
      response_model: opts.response_model,
      provider: opts.provider,
      embeddings: Map.get(opts, :embeddings, Cake.Embeddings),
      responses: Map.get(opts, :responses, Cake.Responses),
      generation: Map.get(opts, :generation, Cake.Generation.OpenAI),
      decomposition: Map.get(opts, :decomposition),
      max_context_tokens:
        Map.get(
          opts,
          :max_context_tokens,
          Application.get_env(
            :cake,
            :decomposition_max_context_tokens,
            @default_max_context_tokens
          )
        ),
      gds: opts.gds
    }
  end

  @spec autoask(pid(), String.t()) :: :ok
  def autoask(pid, question), do: GenServer.cast(pid, {:autoask, question})

  @impl GenServer
  @spec handle_cast(term(), State.t()) :: {:noreply, State.t()}
  def handle_cast({:autoask, question}, %State{state: :idle} = s) do
    {:noreply, spawn_turn(question, s)}
  end

  @impl GenServer
  def handle_cast({:autoask, question}, %State{state: :generating} = s) do
    {:noreply, %{s | queued_question: question}}
  end

  @impl GenServer
  @spec handle_info(term(), State.t()) :: {:noreply, State.t()}
  def handle_info({ref, result}, %State{turn_ref: ref} = s) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    new_state =
      case result do
        {:ok, {response, citations, returned_state}} ->
          _ = emit_response(s, response, citations)
          apply_turn_result(%{s | state: :idle, turn_ref: nil}, returned_state)

        {:error, error} ->
          _ = emit_error(s, error)
          %{s | state: :idle, turn_ref: nil, errors: [error | s.errors]}
      end

    maybe_replay_queue(new_state)
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{turn_ref: ref} = s) do
    _ = emit_error(s, reason)
    new_state = %{s | state: :idle, turn_ref: nil, errors: [reason | s.errors]}
    maybe_replay_queue(new_state)
  end

  # --- Manual mode ---

  @spec manualask(pid(), String.t()) ::
          {:ok, [Result.t()]} | {:error, String.t() | Cake.Search.Backend.search_error()}
  def manualask(pid, question) do
    GenServer.call(pid, {:manualask, question})
  end

  @spec select_docs(pid(), [String.t()]) ::
          :ok | {:error, {:unknown_doc_ids, [String.t()]} | Cake.Generation.error_reason()}
  def select_docs(pid, doc_ids) do
    GenServer.call(pid, {:select, doc_ids})
  end

  # --- Auto-mode turn pipeline ---

  defp run_turn(question, %State{} = s) do
    with {:ok, decomposition} <- maybe_decompose(question, s) do
      run_turn_for(decomposition, question, s)
    end
  end

  # Decomposition drives the first turn only: cached search results mean
  # the question flows through the standard chain (and its reuse clause).
  defp maybe_decompose(_question, %State{search_results: results}) when results != [] do
    {:ok, nil}
  end

  defp maybe_decompose(_question, %State{decomposition: nil}), do: {:ok, nil}

  defp maybe_decompose(question, %State{} = s), do: s.decomposition.decompose(question, [])

  defp run_turn_for(
         %Cake.Decomposition.Result{strategy: :sequential} = decomposition,
         question,
         s
       ) do
    run_sequential_turn(question, decomposition, s)
  end

  defp run_turn_for(decomposition, question, %State{} = s) do
    with {:ok, scored_results} <- resolve_context(decomposition, question, s),
         {:ok, indexed_chunks} <- select(scored_results),
         {:ok, messages} <- build_prompt(indexed_chunks, question, s.message_history),
         {:ok, response} <- generate(messages, s),
         {:ok, result} <- process_response(response, indexed_chunks, s) do
      finalize_turn(s, scored_results, question, response, result)
    end
  end

  defp resolve_context(nil, question, %State{} = s), do: resolve_search_results(question, s)

  defp resolve_context(%Cake.Decomposition.Result{} = decomposition, _question, %State{} = s) do
    search_decomposed(decomposition, s)
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

  # Decomposition dispatch lives upstream in maybe_decompose/2 and
  # resolve_context/3; this stage only reuses cached results or runs the
  # plain single search.
  @doc false
  @spec resolve_search_results(String.t(), State.t()) ::
          {:ok, [Result.t()]}
          | {:error, String.t() | Cake.Search.Backend.search_error()}
  def resolve_search_results(_question, %State{search_results: results}) when results != [] do
    {:ok, results}
  end

  def resolve_search_results(question, %State{} = s) do
    embed_and_search(question, s)
  end

  # An atomic decomposition takes the same single-search path as no
  # decomposition at all; a decomposed one searches every sub-question
  # concurrently, all-or-nothing: any sub-search error or timeout fails the
  # turn, reporting the lowest-index failure.
  defp search_decomposed(%Cake.Decomposition.Result{sub_questions: []} = decomposition, s) do
    embed_and_search(decomposition.original_question, s)
  end

  defp search_decomposed(%Cake.Decomposition.Result{} = decomposition, s) do
    with {:ok, groups} <- search_sub_questions(decomposition, s) do
      {:ok, merge_decomposed_results(groups)}
    end
  end

  # Fan-out reuses the shared Cake.TaskSupervisor (the turn task's home). If
  # decomposition ever climbs above ~5 sub-questions per turn, give
  # sub-search fan-out a dedicated Task.Supervisor so it can't starve turn
  # tasks.
  defp search_sub_questions(decomposition, s) do
    result =
      Cake.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(
        Enum.sort_by(decomposition.question_index, fn {index, _entry} -> index end),
        fn {index, entry} ->
          with {:ok, results} <- embed_and_search(entry.question, s) do
            {:ok, stamp_decomposition(results, decomposition, index)}
          end
        end,
        ordered: true,
        max_concurrency: max_sub_search_concurrency(),
        timeout: sub_search_timeout(),
        on_timeout: :kill_task
      )
      |> Enum.reduce_while({:ok, []}, &collect_sub_search/2)

    with {:ok, groups} <- result, do: {:ok, Enum.reverse(groups)}
  end

  # `ordered: true` yields task outcomes in question_index order, so the
  # first non-ok outcome is the lowest-index failure; halting also shuts
  # down the still-running sibling tasks.
  defp collect_sub_search({:ok, {:ok, group}}, {:ok, groups}),
    do: {:cont, {:ok, [group | groups]}}

  defp collect_sub_search({:ok, {:error, _} = error}, _acc), do: {:halt, error}
  defp collect_sub_search({:exit, :timeout}, _acc), do: {:halt, {:error, :sub_search_timeout}}

  defp collect_sub_search({:exit, reason}, _acc),
    do: {:halt, {:error, {:sub_search_crashed, reason}}}

  defp max_sub_search_concurrency do
    Application.get_env(:cake, :max_sub_search_concurrency, @default_max_sub_search_concurrency)
  end

  # JC-1 fixed the production ceiling at 30s; the config read exists so
  # tests can shrink it to trigger the timeout path deterministically.
  defp sub_search_timeout do
    Application.get_env(:cake, :sub_search_timeout, @default_sub_search_timeout)
  end

  defp stamp_decomposition([], _decomposition, _index), do: []

  # Results from one search call share a single Provenance by reference (see
  # Cake.Search.Provenance), so stamp one updated copy and share it across
  # the group rather than allocating a copy per result.
  defp stamp_decomposition(
         [%Result{provenance: provenance} | _] = results,
         decomposition,
         index
       ) do
    updated_provenance = %{
      provenance
      | decomposed: true,
        original_query: decomposition.original_question,
        sub_question_index: index
    }

    Enum.map(results, &%{&1 | provenance: updated_provenance})
  end

  @doc false
  @spec merge_decomposed_results([[Result.t()]]) :: [Result.t()]
  def merge_decomposed_results(groups) when is_list(groups) do
    groups
    |> List.flatten()
    |> Enum.group_by(fn %Result{retrieval_unit: unit} -> Cake.Citable.metadata(unit).id end)
    |> Enum.map(fn {_id, duplicates} -> Enum.max_by(duplicates, & &1.relevance_score) end)
    |> Cake.Search.sort_by_relevance()
  end

  # --- Sequential (least-to-most) turn pipeline ---

  # Resolve sub-questions in topological order, each step conditioning on
  # the accumulated prior answers, then synthesize the final answer over
  # the merged, deduplicated context plus those answers. Inherently serial
  # — the concurrent fan-out applies only to the flat strategy.
  defp run_sequential_turn(question, %Cake.Decomposition.Result{} = decomposition, %State{} = s) do
    with {:ok, {answer_pairs, groups}} <- resolve_sub_questions(decomposition, s),
         merged = merge_decomposed_results(groups),
         {:ok, indexed_chunks} <- select(merged),
         messages = final_sequential_prompt(indexed_chunks, question, answer_pairs, s),
         {:ok, response} <- generate(messages, s),
         {:ok, result} <- process_response(response, indexed_chunks, s) do
      finalize_turn(s, merged, question, response, result)
    end
  end

  # Accumulators build newest-first; normalize_sub_question_groups flips
  # both back to resolution order (prompts want prior answers oldest-first).
  defp resolve_sub_questions(decomposition, %State{} = s) do
    decomposition
    |> Cake.Decomposition.Result.topological_order()
    |> Enum.reduce_while({:ok, {[], []}}, fn {index, entry}, {:ok, {answers_rev, groups}} ->
      prior_answers = Enum.reverse(answers_rev)

      case resolve_sub_question(entry, index, decomposition, prior_answers, s) do
        {:ok, {answer, stamped}} ->
          {:cont, {:ok, {[{entry.question, answer} | answers_rev], [stamped | groups]}}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> normalize_sub_question_groups()
  end

  defp normalize_sub_question_groups({:ok, {answers_rev, groups}}) do
    {:ok, {Enum.reverse(answers_rev), Enum.reverse(groups)}}
  end

  defp normalize_sub_question_groups({:error, _} = error), do: error

  defp resolve_sub_question(entry, index, decomposition, prior_answers, %State{} = s) do
    with {:ok, results} <- embed_and_search(entry.question, s),
         stamped = stamp_decomposition(results, decomposition, index),
         {:ok, indexed_chunks} <- select(stamped),
         messages =
           Cake.Prompt.build_with_prior_answers(indexed_chunks, entry.question, prior_answers, [],
             max_context_tokens: s.max_context_tokens
           ),
         {:ok, answer} <- generate(messages, s) do
      {:ok, {answer, stamped}}
    end
  end

  defp final_sequential_prompt(indexed_chunks, question, answer_pairs, %State{} = s) do
    Cake.Prompt.build_with_prior_answers(
      indexed_chunks,
      question,
      answer_pairs,
      Enum.reverse(s.message_history),
      max_context_tokens: s.max_context_tokens
    )
  end

  # --- Stage 1a: apply_selection (manual mode) ---

  @doc false
  @spec apply_selection([Result.t()], [String.t()]) ::
          {:ok, [Cake.Prompt.indexed_chunk()]} | {:error, {:unknown_doc_ids, [String.t()]}}
  def apply_selection(candidates, doc_ids) when is_list(candidates) do
    available_ids =
      MapSet.new(candidates, fn %Result{retrieval_unit: unit} ->
        Cake.Citable.metadata(unit).id
      end)

    requested = MapSet.new(doc_ids)
    unknown = MapSet.difference(requested, available_ids)

    if MapSet.size(unknown) > 0 do
      {:error, {:unknown_doc_ids, MapSet.to_list(unknown)}}
    else
      {:ok, index_selected(candidates, doc_ids)}
    end
  end

  defp index_selected(candidates, doc_ids) do
    candidates
    |> Enum.filter(fn %Result{retrieval_unit: unit} ->
      Cake.Citable.metadata(unit).id in doc_ids
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {result, idx} -> {idx, result} end)
  end

  # --- Stage 1b: select (auto mode) ---

  @doc false
  @spec select([Result.t()]) :: {:ok, [Cake.Prompt.indexed_chunk()]}
  def select(scored_results) when is_list(scored_results) do
    {indexed_chunks, _context_quality} = Cake.Prompt.prepare_context(scored_results)
    {:ok, indexed_chunks}
  end

  # --- Stage 2: prompt ---

  @doc false
  @spec build_prompt([Cake.Prompt.indexed_chunk()], String.t(), [String.t()]) ::
          {:ok, [Cake.Prompt.message()]}
  def build_prompt(indexed_chunks, question, history) do
    {:ok, Cake.Prompt.build(indexed_chunks, question, Enum.reverse(history))}
  end

  # --- Stage 3: generate ---

  @doc false
  @spec generate([Cake.Prompt.message()], State.t()) ::
          {:ok, String.t()} | {:error, Cake.Generation.error_reason()}
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
        [] -> [response, question]
        _ -> [response, question | s.message_history]
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
           Cake.Search.search_chunks_with_context(
             :hybrid,
             question,
             embedding,
             Cake.Search.default_expand_offset(),
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
  @spec handle_call(term(), GenServer.from(), State.t()) :: {:reply, term(), State.t()}
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

  defp spawn_turn(question, %State{} = s) do
    _ = broadcast(s, {:state_change, :generating})
    task = Task.Supervisor.async_nolink(Cake.TaskSupervisor, fn -> run_turn(question, s) end)
    %{s | state: :generating, turn_ref: task.ref}
  end

  defp apply_turn_result(%State{} = current, %State{} = returned) do
    %{
      current
      | search_results: returned.search_results,
        message_history: returned.message_history,
        chunk_map: returned.chunk_map,
        citations: returned.citations
    }
  end

  defp maybe_replay_queue(%State{queued_question: nil} = s) do
    {:noreply, s}
  end

  defp maybe_replay_queue(%State{queued_question: question} = s) do
    {:noreply, spawn_turn(question, %{s | queued_question: nil})}
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
