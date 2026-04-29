defmodule Cake.Search.Result do
  @moduledoc """
  Normalized, self-describing search result.

  Every retrieval artifact in the pipeline is wrapped in this struct from
  the moment it leaves the search backend until it reaches the end of the
  Responses pipeline. It is the single carrier of:

  - The retrieval unit (the Ecto struct)
  - Backend-provided score
  - CAKE-computed scores (cosine, relevance)
  - Hit provenance (direct search vs. expansion)
  - Search conditions (via `Provenance`)
  - Prompt index (assigned by `Prompt.prepare_context/2`)

  ## Lifecycle

  1. `new_from_search/4` / `new_from_expansion/3` — constructed in
     `Search.OpenSearch` with `backend_score`, `hit_source`, `index`, and
     `provenance`. CAKE-computed scores start `nil`.
  2. `Search.score_results/2` — populates `cosine_score`.
  3. `Search.normalize_and_combine/1` — populates `relevance_score`.
  4. `Prompt.prepare_context/2` — populates `prompt_index`.
  5. `Responses.process/3` — reads `prompt_index` and `retrieval_unit`
     to build the citation map.
  """

  alias Cake.Search.Provenance

  @type hit_source :: :search | :expansion

  @type t :: %__MODULE__{
          retrieval_unit: struct(),
          backend_score: float() | nil,
          cosine_score: float() | nil,
          relevance_score: float() | nil,
          hit_source: hit_source(),
          index: String.t(),
          provenance: Provenance.t(),
          prompt_index: pos_integer() | nil
        }

  @enforce_keys [:retrieval_unit, :hit_source, :index, :provenance]
  defstruct [
    :retrieval_unit,
    :backend_score,
    :cosine_score,
    :relevance_score,
    :hit_source,
    :index,
    :provenance,
    :prompt_index
  ]

  @doc """
  Build a Result from a direct search hit. `unit` is the hydrated Ecto
  struct, `score` is the raw backend `_score`, `index` is the index name,
  and `provenance` is the shared `%Provenance{}` for this search call.
  """
  @spec new_from_search(struct(), float() | nil, String.t(), Provenance.t()) :: t()
  def new_from_search(unit, score, index, %Provenance{} = provenance) do
    %__MODULE__{
      retrieval_unit: unit,
      backend_score: score,
      hit_source: :search,
      index: index,
      provenance: provenance
    }
  end

  @doc """
  Build a Result from an expanded neighbor (fetched from Postgres, not
  from the search backend). No backend score.
  """
  @spec new_from_expansion(struct(), String.t(), Provenance.t()) :: t()
  def new_from_expansion(unit, index, %Provenance{} = provenance) do
    %__MODULE__{
      retrieval_unit: unit,
      backend_score: nil,
      hit_source: :expansion,
      index: index,
      provenance: provenance
    }
  end
end
