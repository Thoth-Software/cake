defmodule Cake.Responses.Behaviour do
  @moduledoc """
  Contract for post-generation processing of LLM responses.

  Implementations take the raw LLM text, the indexed chunks that provided
  retrieval context, and opts, and return a `Cake.Responses.Result` struct
  containing the final display text, resolved citations, media, actions,
  and any additional assigns for the frontend.

  The return type is `Result.t()`, not a tagged tuple. The pipeline does
  not have operational failure modes — degenerate inputs produce degenerate
  but valid Results. Warnings (e.g., hallucinated citations the LLM
  invented) surface in `Result.warnings` rather than short-circuiting.
  """

  alias Cake.Responses.Result

  @type indexed_chunks :: [{pos_integer(), {struct(), map()}}]

  @callback process(
              raw_text :: String.t(),
              indexed_chunks :: indexed_chunks(),
              opts :: keyword()
            ) :: Result.t()
end
