defmodule Cake.Conversation.State do
  @moduledoc """
  Internal state for the Conversation GenServer.

  ## States

  * `:idle` — ready to receive a new question.
  * `:retrieving` — manual-mode question received; a task is retrieving
    candidates. `pending` holds the question with `candidates: nil`.
  * `:awaiting_selection` — candidates retrieved, waiting for user to
    pick documents. `pending` holds the question and candidate list.
  * `:generating` — a task is running the pipeline; transitions back to
    `:idle` when the response is ready.

  `turn_ref` is the monitor reference of the task running the current
  `:retrieving` or `:generating` stage, `nil` otherwise. `owner_ref` is
  the monitor reference on the optional `:owner` process whose exit stops
  the conversation, `nil` when no owner was given.

  ## Transitions

      :idle --{:autoask, q}-->       :generating        --> :idle
      :idle --{:manualask, q}-->     :retrieving        --> :awaiting_selection
      :awaiting_selection --{:select, ids}--> :generating --> :idle

  An `:autoask` during `:generating` is queued in `queued_question` (a
  later one overwrites an earlier one) and replayed when the turn
  completes; every other invalid transition crashes the GenServer (no
  defensive clauses).
  """

  @type state_name :: :idle | :retrieving | :awaiting_selection | :generating

  @type t :: %__MODULE__{
          id: String.t(),
          state: state_name(),
          pending: %{question: String.t(), candidates: list() | nil} | nil,
          turn_ref: reference() | nil,
          owner_ref: reference() | nil,
          queued_question: String.t() | nil,
          embedder: String.t(),
          response_model: String.t(),
          provider: atom(),
          embeddings: module(),
          responses: module(),
          generation: module(),
          decomposition: module() | nil,
          max_context_tokens: non_neg_integer(),
          max_self_ask_iterations: non_neg_integer(),
          max_ircot_iterations: non_neg_integer(),
          gds: module(),
          search_results: list() | nil,
          message_history: list(),
          chunk_map: map(),
          citations: list(),
          errors: list()
        }

  # The budget fields are enforced rather than defaulted: their defaults
  # live in config.exs (read at runtime by Conversation.build_state/1, the
  # sole constructor), and a struct-level copy could silently drift from
  # the config value.
  @enforce_keys [
    :id,
    :embedder,
    :response_model,
    :provider,
    :gds,
    :max_context_tokens,
    :max_self_ask_iterations,
    :max_ircot_iterations
  ]
  defstruct [
    :id,
    :embedder,
    :response_model,
    :provider,
    :gds,
    :max_context_tokens,
    :max_self_ask_iterations,
    :max_ircot_iterations,
    state: :idle,
    pending: nil,
    turn_ref: nil,
    owner_ref: nil,
    queued_question: nil,
    embeddings: Cake.Embeddings,
    responses: Cake.Responses,
    generation: Cake.Generation.OpenAI,
    decomposition: nil,
    # nil is the uninitialized sentinel: no retrieval has completed yet.
    # Any list — [] included — is a completed retrieval to be reused, so
    # "searched, found nothing" is distinguishable from "never searched".
    search_results: nil,
    message_history: [],
    chunk_map: %{},
    citations: [],
    errors: []
  ]
end
