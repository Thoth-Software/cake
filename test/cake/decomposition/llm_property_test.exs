defmodule Cake.Decomposition.LLMPropertyTest do
  @moduledoc """
  Property tests for `Cake.Decomposition.LLM`.

  The core invariant: whatever valid JSON map the generation mock hands back
  as `parsed`, `decompose/2` returns `{:ok, Result.t()}` or `{:error, _}` —
  it never crashes on an unexpected shape.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Mox

  alias Cake.Decomposition.LLM
  alias Cake.Decomposition.Result

  setup :verify_on_exit!

  defp json_value do
    StreamData.one_of([
      StreamData.boolean(),
      StreamData.integer(),
      StreamData.string(:printable, max_length: 20),
      StreamData.list_of(StreamData.string(:printable, max_length: 10), max_length: 3)
    ])
  end

  # Arbitrary JSON objects, biased toward the two shapes the schema describes
  # so both parse paths are exercised alongside the garbage ones.
  defp parsed_map do
    StreamData.one_of([
      StreamData.constant(%{"atomic" => true}),
      StreamData.map(
        StreamData.list_of(StreamData.string(:printable, max_length: 20), max_length: 4),
        &%{"sub_questions" => &1}
      ),
      StreamData.map_of(StreamData.string(:printable, max_length: 10), json_value(),
        max_length: 4
      )
    ])
  end

  property "any valid JSON map from the mock yields {:ok, Result.t()} or {:error, _}" do
    check all(parsed <- parsed_map()) do
      expect(Cake.Generation.Mock, :complete_json, fn _messages, _model, _opts ->
        {:ok,
         %{
           text: Jason.encode!(parsed),
           finish_reason: :stop,
           usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2},
           model: "test-model",
           parsed: parsed
         }}
      end)

      case LLM.decompose("any question", generation: Cake.Generation.Mock) do
        {:ok, %Result{} = result} -> assert result.original_question == "any question"
        {:error, reason} -> assert elem(reason, 0) in [:invalid_response, :generation]
      end
    end
  end
end
