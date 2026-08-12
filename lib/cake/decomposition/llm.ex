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

  @default_generation Cake.Generation.OpenAI
  @default_model "gpt-4o-mini"

  # Mirrors the response shapes Prompt.decomposition_prompt/1 instructs the
  # model to produce.
  @schema %{
    "type" => "object",
    "properties" => %{
      "atomic" => %{"type" => "boolean"},
      "sub_questions" => %{"type" => "array", "items" => %{"type" => "string"}}
    },
    "additionalProperties" => false
  }

  @impl Cake.Decomposition
  @spec decompose(String.t(), keyword()) ::
          {:ok, Result.t()} | {:error, Cake.Decomposition.error_reason()}
  def decompose(question, opts \\ [])

  def decompose(question, opts) when is_binary(question) do
    generation = Keyword.get(opts, :generation, @default_generation)
    model = Keyword.get(opts, :model, @default_model)
    messages = Cake.Prompt.decomposition_prompt(question)

    case generation.complete_json(messages, model, schema: @schema) do
      {:ok, %{parsed: parsed}} -> parse_result(question, parsed)
      {:error, reason} -> {:error, {:generation, reason}}
    end
  end

  defp parse_result(_question, %{"atomic" => true, "sub_questions" => _} = parsed) do
    {:error, {:invalid_response, "unexpected decomposition shape: #{inspect(parsed)}"}}
  end

  defp parse_result(question, %{"atomic" => true}), do: {:ok, Result.new(question)}

  defp parse_result(question, %{"sub_questions" => sub_questions}) when is_list(sub_questions) do
    {:ok, Result.new(question, sub_questions)}
  end

  defp parse_result(_question, parsed) do
    {:error, {:invalid_response, "unexpected decomposition shape: #{inspect(parsed)}"}}
  end
end
