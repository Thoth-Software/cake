defmodule Cake.Generation.OpenAIPropertyTest do
  @moduledoc """
  Property tests for `Cake.Generation.OpenAI.complete_json/3`.

  The core invariant: no matter what the model emits as its output text —
  valid JSON, malformed JSON, or arbitrary noise — `complete_json/3` always
  returns a well-formed result tuple and never crashes.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cake.Generation.OpenAI

  @default_messages [%{role: "user", content: "hello"}]
  @default_model "gpt-4o"

  @object_schema %{
    "type" => "object",
    "properties" => %{"atomic" => %{"type" => "boolean"}}
  }

  property "never crashes on arbitrary model output text" do
    check all(text <- StreamData.string(:printable)) do
      Req.Test.stub(OpenAI, fn conn ->
        Req.Test.json(conn, %{
          "output" => [%{"status" => "completed", "content" => [%{"text" => text}]}],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2},
          "model" => "gpt-4o"
        })
      end)

      result = OpenAI.complete_json(@default_messages, @default_model, schema: @object_schema)

      assert match?({:ok, %{parsed: parsed}} when is_map(parsed), result) or
               match?({:error, {:malformed_json, _, _}}, result)
    end
  end
end
