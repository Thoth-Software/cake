defmodule Cake.Generation.Anthropic do
  @moduledoc """
  Anthropic implementation of the `Cake.Generation` behaviour.

  Placeholder — returns `{:error, {:provider_error, _}}` for all calls.
  Full implementation blocked on (1) Anthropic API credentials in config,
  (2) a decision on whether to use the Messages API directly or via a
  library like `:anthropix`.
  """

  @behaviour Cake.Generation

  @impl Cake.Generation
  @spec complete(
          Cake.Generation.messages(),
          Cake.Generation.model(),
          Cake.Generation.complete_opts()
        ) ::
          {:ok, Cake.Generation.completion()} | {:error, Cake.Generation.error_reason()}
  def complete(_messages, _model, _opts \\ []) do
    {:error, {:provider_error, "Cake.Generation.Anthropic not implemented"}}
  end

  @impl Cake.Generation
  @spec complete_json(
          Cake.Generation.messages(),
          Cake.Generation.model(),
          Cake.Generation.json_opts()
        ) ::
          {:ok, Cake.Generation.json_completion()} | {:error, Cake.Generation.error_reason()}
  def complete_json(_messages, _model, _opts \\ []) do
    {:error, {:provider_error, "Cake.Generation.Anthropic not implemented"}}
  end
end
