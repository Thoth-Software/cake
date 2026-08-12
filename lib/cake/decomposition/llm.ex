defmodule Cake.Decomposition.LLM do
  @moduledoc """
  LLM-backed implementation of the `Cake.Decomposition` behaviour.

  Builds the decomposition prompt via `Cake.Prompt.decomposition_prompt/1` and
  sends it through `c:Cake.Generation.complete_json/3` with a JSON schema
  describing the expected response shape. The validated JSON is parsed into a
  `Cake.Decomposition.Result`: `{"atomic": true}` yields an atomic result and
  `{"sub_questions": [...]}` a flat decomposition.

  This module does no HTTP — the LLM call boundary is `Cake.Generation`. The
  generation module is injected via the `:generation` opt (defaulting to
  `Cake.Generation.OpenAI`), so tests substitute `Cake.Generation.Mock`.
  """

  @behaviour Cake.Decomposition

  alias Cake.Decomposition.Result

  @impl Cake.Decomposition
  @spec decompose(String.t(), keyword()) ::
          {:ok, Result.t()} | {:error, Cake.Decomposition.error_reason()}
  def decompose(question, opts \\ [])

  # Placeholder: replaced once the tests pinning the contract are in place.
  def decompose(question, opts) when is_binary(question) do
    _ = opts
    {:error, {:invalid_response, "not implemented"}}
  end
end
