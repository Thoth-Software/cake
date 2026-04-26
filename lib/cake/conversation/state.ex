defmodule Cake.Conversation.State do
  @moduledoc """
  Internal state for the Conversation GenServer.

  ## States

  * `:idle` — ready to receive a new question.
  * `:awaiting_selection` — manual-mode question received, candidates
    retrieved, waiting for user to pick documents. `pending` holds
    the question and candidate list.
  * `:generating` — running the pipeline; transitions back to `:idle`
    when the response is ready.

  ## Transitions

      :idle --{:autoask, q}-->       :generating        --> :idle
      :idle --{:manualask, q}-->     :awaiting_selection
      :awaiting_selection --{:select, ids}--> :generating --> :idle

  Invalid transitions crash the GenServer (no defensive clauses).
  """

  @type state_name :: :idle | :awaiting_selection | :generating

  @type t :: %__MODULE__{
          id: String.t(),
          state: state_name(),
          pending: %{question: String.t(), candidates: list()} | nil,
          search: module(),
          reply_to: pid(),
          embedder: String.t(),
          response_model: String.t(),
          provider: atom(),
          embeddings: module(),
          responses: module(),
          generation: module(),
          gds: module(),
          search_results: list(),
          message_history: list(),
          chunk_map: map(),
          citations: list(),
          errors: list()
        }

  @enforce_keys [:id, :search, :reply_to, :embedder, :response_model, :provider, :gds]
  defstruct [
    :id,
    :search,
    :reply_to,
    :embedder,
    :response_model,
    :provider,
    :gds,
    state: :idle,
    pending: nil,
    embeddings: Cake.Embeddings,
    responses: Cake.Responses,
    generation: Cake.Generation.OpenAI,
    search_results: [],
    message_history: [],
    chunk_map: %{},
    citations: [],
    errors: []
  ]
end
