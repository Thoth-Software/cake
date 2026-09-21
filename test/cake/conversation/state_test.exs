defmodule Cake.Conversation.StateTest do
  @moduledoc """
  Pins `Cake.Conversation.State`'s construction contract: the budget
  fields (`:max_context_tokens`, `:max_self_ask_iterations`) are enforced
  keys with no struct defaults. `Conversation.build_state/1` is the sole
  constructor and always supplies them from opts or config, so a
  hand-built `State` that forgot one must fail loudly rather than carry a
  copy of the config default that could silently drift from `config.exs`.
  """

  use ExUnit.Case, async: true

  alias Cake.Conversation.State

  defp enforced_attrs do
    %{
      id: "state-test",
      embedder: "text-embedding-ada-002",
      response_model: "gpt-4o-mini",
      provider: :openai,
      gds: Cake.Support.FixtureGDS,
      max_context_tokens: 4096,
      max_self_ask_iterations: 5
    }
  end

  test "constructs with every enforced key supplied" do
    state = struct!(State, enforced_attrs())

    assert state.max_context_tokens == 4096
    assert state.max_self_ask_iterations == 5
  end

  test "raises without :max_context_tokens" do
    assert_raise ArgumentError, ~r/max_context_tokens/, fn ->
      struct!(State, Map.delete(enforced_attrs(), :max_context_tokens))
    end
  end

  test "raises without :max_self_ask_iterations" do
    assert_raise ArgumentError, ~r/max_self_ask_iterations/, fn ->
      struct!(State, Map.delete(enforced_attrs(), :max_self_ask_iterations))
    end
  end

  test "raises without :max_ircot_iterations" do
    assert_raise ArgumentError, ~r/max_ircot_iterations/, fn ->
      struct!(State, Map.delete(enforced_attrs(), :max_ircot_iterations))
    end
  end
end
