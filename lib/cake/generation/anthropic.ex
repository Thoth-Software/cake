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
  def complete(_messages, _model, _opts \\ []) do
    {:error, {:provider_error, "Cake.Generation.Anthropic not implemented"}}
  end
end
