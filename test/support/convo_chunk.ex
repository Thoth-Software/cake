defmodule Cake.Test.ConvoChunk do
  @moduledoc """
  Test struct for `Cake.Conversation` tests. Implements both
  `Cake.Promptable` (consumed by `Cake.Prompt.format_chunk/1`) and
  `Cake.Citable` (consumed by `Cake.Responses.build_citation_map/1`)
  so a single struct can flow through the entire turn pipeline.

  Distinct from `Cake.Test.StubChunk`, which only implements `Citable` and
  is owned by the Responses tests.

  Also carries an `:embedding` field because `Cake.Search.score_results/2`
  reads `unit.embedding` to compute cosine similarity. A nil embedding is
  scored as 0.0; a list of floats is scored against the query embedding.
  """

  @type t :: %__MODULE__{
          embedding: [float()] | nil,
          prompt_text: String.t(),
          metadata: Cake.Citable.metadata()
        }

  defstruct embedding: nil, prompt_text: "", metadata: %{}
end

defimpl Cake.Promptable, for: Cake.Test.ConvoChunk do
  @spec prompt_context(Cake.Test.ConvoChunk.t()) :: String.t()
  def prompt_context(%{prompt_text: t}), do: t
end

defimpl Cake.Citable, for: Cake.Test.ConvoChunk do
  @spec metadata(Cake.Test.ConvoChunk.t()) :: Cake.Citable.metadata()
  def metadata(%{metadata: m}), do: m
end
