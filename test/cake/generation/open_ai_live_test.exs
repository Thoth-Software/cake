defmodule Cake.Generation.OpenAILiveTest do
  @moduledoc """
  `Cake.Generation.OpenAI.complete/3` against the real Responses API
  (#247, item 6).

  The unit tests in `Cake.Generation.OpenAITest` pin the parser against
  the wire format as we understand it; only a live call can show that the
  provider still speaks it. So: the success parse (`text`, `model`),
  the `finish_reason` mapping, usage normalization, and the auth error
  path. Shapes and invariants only — never what the model said.

  `finish_reason: :length` is not provoked here: `t:Cake.Generation.complete_opts/0`
  has no max-output-tokens option, so there is no way to truncate a reply
  through the production call. A naturally finished reply mapping to
  `:stop` is the observable half of the mapping.
  """

  use Cake.LiveLLMCase

  alias Cake.Generation.OpenAI

  @messages [
    %{role: "system", content: "You are a terse assistant. Reply in one short sentence."},
    %{role: "user", content: "Name one primary color."}
  ]
  @wrong_key "sk-not-a-real-key"

  defp model, do: production_response_model()

  describe "complete/3 against the Responses API" do
    test "parses a completed response into the normalized completion" do
      assert {:ok, completion} = OpenAI.complete(@messages, model())

      assert completion |> Map.keys() |> Enum.sort() == [:finish_reason, :model, :text, :usage]
      assert is_binary(completion.text) and String.trim(completion.text) != ""
      # The provider reports the resolved snapshot (e.g. "gpt-4o-mini-2024-07-18").
      assert is_binary(completion.model) and String.starts_with?(completion.model, model())
    end

    test "maps a naturally finished reply to finish_reason :stop" do
      assert {:ok, %{finish_reason: :stop}} = OpenAI.complete(@messages, model())
    end

    test "normalizes usage to integer input, output and total token counts that add up" do
      assert {:ok, %{usage: usage}} = OpenAI.complete(@messages, model())

      assert %{input_tokens: input, output_tokens: output, total_tokens: total} = usage
      assert map_size(usage) == 3
      assert is_integer(input) and input > 0
      assert is_integer(output) and output > 0
      assert total == input + output
    end

    test "the endpoint accepts the temperature option the request builder sends" do
      assert {:ok, %{finish_reason: :stop}} =
               OpenAI.complete(@messages, model(), temperature: 0.0)
    end
  end

  describe "complete/3 with a wrong key" do
    test "returns {:error, {:auth, _}} rather than raising or retrying" do
      configure_live!(@wrong_key)

      assert {:error, {:auth, detail}} = OpenAI.complete(@messages, model())
      assert byte_size(detail) > 0
    end
  end
end
