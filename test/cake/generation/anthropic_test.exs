defmodule Cake.Generation.AnthropicTest do
  @moduledoc """
  Tests for the Anthropic Generation stub.

  Full implementation is deferred — this test suite locks in the stub
  behaviour so that when the real implementation arrives, removing or
  altering it is a conscious decision flagged by failing tests.
  """

  use ExUnit.Case, async: true

  alias Cake.Generation.Anthropic

  test "complete/3 returns {:error, {:provider_error, _}} for any call" do
    assert {:error, {:provider_error, msg}} =
             Anthropic.complete([%{role: "user", content: "hi"}], "claude-3-5-sonnet")

    assert msg =~ "not implemented"
  end

  test "complete/3 accepts opts without raising" do
    assert {:error, {:provider_error, _}} =
             Anthropic.complete(
               [%{role: "user", content: "hi"}],
               "claude-3-5-sonnet",
               timeout: 5_000,
               temperature: 0.5
             )
  end
end
