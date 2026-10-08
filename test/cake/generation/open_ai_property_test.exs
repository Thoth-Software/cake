defmodule Cake.Generation.OpenAIPropertyTest do
  @moduledoc """
  Property tests for `Cake.Generation.OpenAI`.

  The core invariant: whatever the provider sends back — a well-formed
  Responses API body, a body of arbitrary shape, arbitrary model output text,
  a 429 with any `Retry-After` header — `complete/3` and `complete_json/3`
  return a well-formed result tuple from the documented taxonomy and never
  crash. Usage normalisation is pinned for both shapes the provider has used.
  Example tests live in `open_ai_test.exs`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cake.Generation.OpenAI

  # Every error outcome logs a warning; hundreds of them per property.
  @moduletag capture_log: true

  @default_messages [%{role: "user", content: "hello"}]
  @default_model "gpt-4o"

  @object_schema %{
    "type" => "object",
    "properties" => %{"atomic" => %{"type" => "boolean"}}
  }

  @error_tags [
    :transport,
    :timeout,
    :rate_limited,
    :auth,
    :http,
    :malformed_response,
    :malformed_json,
    :empty_response,
    :content_filtered,
    :provider_error
  ]

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp json_scalar,
    do: one_of([string(:printable, max_length: 12), integer(), boolean(), constant(nil)])

  # A JSON-shaped map of up to three arbitrary keys.
  defp json_map,
    do: map_of(string(:alphanumeric, min_length: 1, max_length: 6), json_scalar(), max_length: 3)

  defp maybe(gen), do: one_of([constant(nil), gen])

  # A content block in the shape the parser reads, with each status it knows
  # (and one it does not, and none).
  defp content_block do
    gen all(
          text <- string(:printable, max_length: 20),
          status <- maybe(member_of(["completed", "incomplete", "other"]))
        ) do
      put_present(%{"content" => [%{"text" => text}]}, "status", status)
    end
  end

  # One item of the output list: a content block, a map with a content key of
  # the wrong shape, an arbitrary map, or a scalar.
  defp output_item do
    one_of([
      content_block(),
      map(json_map(), &Map.put(&1, "content", "not a list")),
      map(json_map(), &Map.put(&1, "content", [])),
      json_map(),
      json_scalar()
    ])
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp responses_usage do
    gen all(i <- integer(0..10_000), o <- integer(0..10_000), t <- integer(0..20_000)) do
      %{"input_tokens" => i, "output_tokens" => o, "total_tokens" => t}
    end
  end

  defp legacy_usage do
    gen all(i <- integer(0..10_000), o <- integer(0..10_000), t <- integer(0..20_000)) do
      %{"prompt_tokens" => i, "completion_tokens" => o, "total_tokens" => t}
    end
  end

  # A 200 body of arbitrary shape: each of output, usage and model present or
  # absent, and when present as a list or a scalar, a known usage shape or junk.
  defp arbitrary_body do
    gen all(
          output <-
            maybe(one_of([list_of(output_item(), max_length: 3), json_scalar(), json_map()])),
          usage <- maybe(one_of([responses_usage(), legacy_usage(), json_map(), json_scalar()])),
          model <- maybe(string(:alphanumeric, min_length: 1, max_length: 12))
        ) do
      %{}
      |> put_present("output", output)
      |> put_present("usage", usage)
      |> put_present("model", model)
    end
  end

  # The header forms Req itself accepts. Req reads Retry-After for its own
  # retry schedule before this module sees the response, and raises on
  # anything but a bare integer or an HTTP date, so other shapes are Req's
  # contract, not this module's. `nil` means no header at all.
  defp retry_after_header do
    one_of([
      map(integer(0..100_000), &Integer.to_string/1),
      map(
        integer(0..3_600),
        &Req.Utils.format_http_date(DateTime.add(~U[2030-01-01 00:00:00Z], &1))
      ),
      constant(nil)
    ])
  end

  defp put_retry_after(conn, nil), do: conn
  defp put_retry_after(conn, header), do: Plug.Conn.put_resp_header(conn, "retry-after", header)

  defp stub_200(body), do: Req.Test.stub(OpenAI, &Req.Test.json(&1, body))

  defp taxonomy_tag({:error, reason}) when is_tuple(reason), do: elem(reason, 0)

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "complete/3 never crashes on a 200 body of arbitrary shape" do
    check all(body <- arbitrary_body()) do
      stub_200(body)

      case OpenAI.complete(@default_messages, @default_model) do
        {:ok, %{text: text, finish_reason: reason, usage: usage, model: model}} ->
          assert is_binary(text) and text != ""
          assert reason in [:stop, :length]
          assert Enum.sort(Map.keys(usage)) == [:input_tokens, :output_tokens, :total_tokens]
          assert is_binary(model)

        {:error, _reason} = error ->
          assert taxonomy_tag(error) in @error_tags
      end
    end
  end

  property "complete_json/3 never crashes on arbitrary model output text" do
    check all(text <- StreamData.string(:printable)) do
      stub_200(%{
        "output" => [%{"status" => "completed", "content" => [%{"text" => text}]}],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2},
        "model" => "gpt-4o"
      })

      result = OpenAI.complete_json(@default_messages, @default_model, schema: @object_schema)

      # Decodable, schema-valid output yields {:ok, %{parsed}}; everything
      # else an {:error, reason} from the taxonomy (:malformed_json for bad or
      # invalid JSON, :empty_response for empty model output, and so on).
      assert match?({:ok, %{parsed: parsed}} when is_map(parsed), result) or
               taxonomy_tag(result) in @error_tags
    end
  end

  property "a 429 yields {:rate_limited, seconds | nil}: seconds from an integer Retry-After, nil from a date or none" do
    check all(header <- retry_after_header()) do
      Req.Test.stub(OpenAI, fn conn ->
        conn
        |> put_retry_after(header)
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => %{"message" => "rate limit"}})
      end)

      assert {:error, {:rate_limited, retry_after}} =
               OpenAI.complete(@default_messages, @default_model, max_retries: 0)

      # An integer header is surfaced as seconds; a date header (or none) as nil.
      case header && Integer.parse(header) do
        {seconds, ""} -> assert retry_after == seconds
        _date_or_absent -> assert retry_after == nil
      end
    end
  end

  property "usage is normalised to the three atom keys from either provider shape, values intact" do
    check all(usage <- one_of([responses_usage(), legacy_usage()])) do
      stub_200(%{
        "output" => [%{"status" => "completed", "content" => [%{"text" => "ok"}]}],
        "usage" => usage
      })

      assert {:ok, %{usage: normalised}} = OpenAI.complete(@default_messages, @default_model)

      [input, output] =
        case usage do
          %{"input_tokens" => i, "output_tokens" => o} -> [i, o]
          %{"prompt_tokens" => i, "completion_tokens" => o} -> [i, o]
        end

      assert normalised == %{
               input_tokens: input,
               output_tokens: output,
               total_tokens: usage["total_tokens"]
             }
    end
  end
end
