defmodule Cake.Search.Provenance do
  @moduledoc """
  Search conditions under which a result was discovered.

  Constructed once per search call and shared (by reference) across all
  `Search.Result` structs from that call. Denormalized onto each result
  because query decomposition and multi-index search merge results from
  heterogeneous searches into a single list — set-level grouping doesn't
  survive the merge.

  For a decomposed search, `sub_question_index` is the sub-question's
  positional key in `Cake.Decomposition.Result`'s `question_index`, so
  citations trace back to a specific sub-question by index rather than by
  string matching.
  """

  @type t :: %__MODULE__{
          search_type: :keyword | :vector | :hybrid,
          query_text: String.t(),
          decomposed: boolean(),
          original_query: String.t() | nil,
          sub_question_index: non_neg_integer() | nil,
          embedding_model: String.t() | nil
        }

  @enforce_keys [:search_type, :query_text]
  defstruct [
    :search_type,
    :query_text,
    :embedding_model,
    decomposed: false,
    original_query: nil,
    sub_question_index: nil
  ]
end
