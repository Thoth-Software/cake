defmodule Cake.Decomposition do
  @moduledoc """
  Behaviour for query-decomposition strategies.

  A strategy inspects a user question and returns a `Cake.Decomposition.Result`
  describing whether the question is atomic or decomposes into sub-questions.
  Strategies are pure: question in, sub-questions out. They never touch
  `Cake.Search` or `Cake.Embeddings` — `Cake.Conversation` performs all
  retrieval and feeds results back in as data (see the Query Decomposition
  epic).

  The first implementation will be `Cake.Decomposition.LLM` (added in #225);
  `Cake.Decomposition.Mock` (Mox) stands in for tests.
  """

  use Boundary, top_level?: true, deps: [Cake, Cake.Generation, Cake.Prompt], exports: [Result]

  alias Cake.Decomposition.Result

  @typedoc """
  Why a decomposition attempt failed. Kept small and pattern-matchable, in the
  same spirit as `t:Cake.Generation.error_reason/0`.

    - `:invalid_response` — the strategy produced output that could not be read
      as a decomposition (e.g. the LLM returned an unexpected shape).
    - `:generation` — an underlying generation call failed; the wrapped term is
      the provider's own error reason.
  """
  @type error_reason ::
          {:invalid_response, String.t()}
          | {:generation, term()}

  @doc """
  Decompose `question` into sub-questions.

  Returns `{:ok, Result.t()}` — an atomic question yields a `Result` whose
  `sub_questions` list is empty — or `{:error, error_reason()}`.
  """
  @callback decompose(question :: String.t(), opts :: keyword()) ::
              {:ok, Result.t()} | {:error, error_reason()}
end
