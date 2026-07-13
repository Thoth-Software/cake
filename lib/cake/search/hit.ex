defmodule Cake.Search.Hit do
  @moduledoc """
  Backend-agnostic search hit.

  Every search backend maps its native hit type into this struct at the
  boundary. Downstream code (GDS `load_from_hits/1`, retrieval modules,
  result builders) works exclusively with `%Hit{}` — never with
  backend-specific types.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          score: float() | nil,
          source: map()
        }

  @enforce_keys [:id]
  defstruct [:id, :score, source: %{}]
end
