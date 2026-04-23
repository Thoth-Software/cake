defmodule Cake.Generation.OpenAITest do
  @moduledoc """
  Tests for `Cake.Generation.OpenAI.complete/3`.

  HTTP is stubbed via `Req.Test`. The module reads `:plug` from its
  application config block, which is set to `{Req.Test, __MODULE__}` in
  `config/test.exs`. Each test registers a per-process stub via
  `Req.Test.stub/2`.

  Covers:
    - Success: new Responses API shape, legacy usage key shape, finish_reason
      derivation, model passthrough.
    - Errors: 401 auth, 429 with/without Retry-After, other HTTP, transport
      timeout/other, malformed body, missing content block, empty content,
      unexpected content structure.
    - Request construction: messages, model, temperature, timeout, retries.
  """

  use ExUnit.Case, async: true

  alias Cake.Generation.OpenAI

  @default_messages [%{role: "user", content: "hello"}]
  @default_model "gpt-4o"

  # ---------------------------------------------------------------------------
  # Success cases
  # ---------------------------------------------------------------------------

  describe "complete/3 success — Responses API shape" do
    test "returns normalized completion on 200 with completed status" do
      Req.Test.stub(OpenAI, fn conn ->
        Req.Test.json(conn, %{
          "output" => [
            %{
              "type" => "message",
              "id" => "msg_1",
              "status" => "completed",
              "role" => "assistant",
              "content" => [
                %{"type" => "output_text", "text" => "Hello world", "annotations" => []}
              ]
            }
          ],
          "usage" => %{
            "input_tokens" => 50,
            "output_tokens" => 5,
            "total_tokens" => 55
          },
          "model" => "gpt-4o-2024-11-20"
        })
      end)

      assert {:ok, completion} = OpenAI.complete(@default_messages, @default_model)
      assert completion.text == "Hello world"
      assert completion.finish_reason == :stop
      assert completion.usage == %{input_tokens: 50, output_tokens: 5, total_tokens: 55}
      assert completion.model == "gpt-4o-2024-11-20"
    end

    test "maps status=incomplete item to finish_reason :length" do
      Req.Test.stub(OpenAI, fn conn ->
        Req.Test.json(conn, %{
          "output" => [
            %{
              "type" => "message",
              "status" => "incomplete",
              "content" => [%{"text" => "partial response..."}]
            }
          ],
          "usage" => %{"input_tokens" => 10, "output_tokens" => 200, "total_tokens" => 210},
          "model" => "gpt-4o"
        })
      end)

      assert {:ok, %{finish_reason: :length, text: "partial response..."}} =
               OpenAI.complete(@default_messages, @default_model)
    end

    test "defaults finish_reason to :stop when status is absent on the item" do
      Req.Test.stub(OpenAI, fn conn ->
        Req.Test.json(conn, %{
          "output" => [
            %{"content" => [%{"text" => "ok"}]}
          ],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2},
          "model" => "gpt-4o"
        })
      end)

      assert {:ok, %{finish_reason: :stop, text: "ok"}} =
               OpenAI.complete(@default_messages, @default_model)
    end

    test "defaults model to \"unknown\" when body omits it" do
      Req.Test.stub(OpenAI, fn conn ->
        Req.Test.json(conn, %{
          "output" => [%{"status" => "completed", "content" => [%{"text" => "x"}]}],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
        })
      end)

      assert {:ok, %{model: "unknown"}} =
               OpenAI.complete(@default_messages, @default_model)
    end
  end

  describe "complete/3 success — usage key variants" do
    test "accepts legacy prompt_tokens/completion_tokens keys" do
      Req.Test.stub(OpenAI, fn conn ->
        Req.Test.json(conn, %{
          "output" => [%{"status" => "completed", "content" => [%{"text" => "x"}]}],
          "usage" => %{
            "prompt_tokens" => 20,
            "completion_tokens" => 30,
            "total_tokens" => 50
          },
          "model" => "gpt-4"
        })
      end)

      assert {:ok, %{usage: usage}} = OpenAI.complete(@default_messages, @default_model)
      assert usage == %{input_tokens: 20, output_tokens: 30, total_tokens: 50}
    end

    test "falls back to zero usage when the shape is unrecognized" do
      Req.Test.stub(OpenAI, fn conn ->
        Req.Test.json(conn, %{
          "output" => [%{"status" => "completed", "content" => [%{"text" => "x"}]}],
          "usage" => %{"weird" => "shape"},
          "model" => "gpt-4"
        })
      end)

      assert {:ok, %{usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}}} =
               OpenAI.complete(@default_messages, @default_model)
    end
  end

  # ---------------------------------------------------------------------------
  # Error cases — HTTP status handling
  # ---------------------------------------------------------------------------

  describe "complete/3 errors — HTTP status" do
    test "401 returns {:error, {:auth, _}}" do
      Req.Test.stub(OpenAI, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"message" => "invalid api key"}})
      end)

      assert {:error, {:auth, body}} = OpenAI.complete(@default_messages, @default_model)
      assert is_binary(body)
    end

    test "429 with Retry-After header returns {:rate_limited, seconds}" do
      Req.Test.stub(OpenAI, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "30")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => %{"message" => "rate limit"}})
      end)

      assert {:error, {:rate_limited, 30}} =
               OpenAI.complete(@default_messages, @default_model, max_retries: 0)
    end

    test "429 without Retry-After returns {:rate_limited, nil}" do
      Req.Test.stub(OpenAI, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => %{"message" => "rate limit"}})
      end)

      assert {:error, {:rate_limited, nil}} =
               OpenAI.complete(@default_messages, @default_model, max_retries: 0)
    end

    test "500 returns {:error, {:http, 500, body}}" do
      Req.Test.stub(OpenAI, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => "server exploded"})
      end)

      assert {:error, {:http, 500, _body}} =
               OpenAI.complete(@default_messages, @default_model, max_retries: 0)
    end

    test "400 returns {:error, {:http, 400, body}}" do
      Req.Test.stub(OpenAI, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "bad request"})
      end)

      assert {:error, {:http, 400, _body}} =
               OpenAI.complete(@default_messages, @default_model)
    end
  end

  # ---------------------------------------------------------------------------
  # Error cases — Transport
  # ---------------------------------------------------------------------------

  describe "complete/3 errors — transport" do
    test "transport timeout returns {:error, {:timeout, _}}" do
      Req.Test.stub(OpenAI, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, {:timeout, _}} =
               OpenAI.complete(@default_messages, @default_model, max_retries: 0)
    end

    test "transport connection refused returns {:error, {:transport, _}}" do
      Req.Test.stub(OpenAI, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, {:transport, :econnrefused}} =
               OpenAI.complete(@default_messages, @default_model, max_retries: 0)
    end
  end

  # ---------------------------------------------------------------------------
  # Error cases — Malformed success responses
  # ---------------------------------------------------------------------------

  describe "complete/3 errors — malformed 200 bodies" do
    test "missing output key returns {:malformed_response, _, body}" do
      Req.Test.stub(OpenAI, fn conn ->
        Req.Test.json(conn, %{"usage" => %{}, "model" => "gpt-4"})
      end)

      assert {:error, {:malformed_response, msg, _body}} =
               OpenAI.complete(@default_messages, @default_model)

      assert msg =~ "output"
    end

    test "missing usage key returns {:malformed_response, _, body}" do
      Req.Test.stub(OpenAI, fn conn ->
        Req.Test.json(conn, %{"output" => [], "model" => "gpt-4"})
      end)

      assert {:error, {:malformed_response, _, _body}} =
               OpenAI.complete(@default_messages, @default_model)
    end

    test "no item has a content key returns {:malformed_response, _, output}" do
      Req.Test.stub(OpenAI, fn conn ->
        Req.Test.json(conn, %{
          "output" => [%{"type" => "reasoning", "summary" => "..."}],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2},
          "model" => "gpt-4"
        })
      end)

      assert {:error, {:malformed_response, msg, _}} =
               OpenAI.complete(@default_messages, @default_model)

      assert msg =~ "content"
    end

    test "empty text in content returns {:empty_response, block}" do
      Req.Test.stub(OpenAI, fn conn ->
        Req.Test.json(conn, %{
          "output" => [
            %{"status" => "completed", "content" => [%{"text" => ""}]}
          ],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 0, "total_tokens" => 1},
          "model" => "gpt-4"
        })
      end)

      assert {:error, {:empty_response, _block}} =
               OpenAI.complete(@default_messages, @default_model)
    end

    test "unexpected content structure returns {:malformed_response, _, _}" do
      Req.Test.stub(OpenAI, fn conn ->
        Req.Test.json(conn, %{
          "output" => [%{"content" => "not a list"}],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2},
          "model" => "gpt-4"
        })
      end)

      assert {:error, {:malformed_response, _, _}} =
               OpenAI.complete(@default_messages, @default_model)
    end
  end

  # ---------------------------------------------------------------------------
  # Request construction
  # ---------------------------------------------------------------------------

  describe "complete/3 request construction" do
    test "sends messages and model in JSON body" do
      test_pid = self()

      Req.Test.stub(OpenAI, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(body)})

        Req.Test.json(conn, success_body())
      end)

      messages = [
        %{role: "system", content: "you are a helpful assistant"},
        %{role: "user", content: "what is 2+2?"}
      ]

      assert {:ok, _} = OpenAI.complete(messages, "gpt-4o-mini")

      assert_receive {:request_body, body}
      assert body["model"] == "gpt-4o-mini"
      assert length(body["input"]) == 2
      assert Enum.at(body["input"], 0)["role"] == "system"
      assert Enum.at(body["input"], 1)["content"] == "what is 2+2?"
    end

    test "includes temperature when passed in opts" do
      test_pid = self()

      Req.Test.stub(OpenAI, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(body)})
        Req.Test.json(conn, success_body())
      end)

      assert {:ok, _} =
               OpenAI.complete(@default_messages, @default_model, temperature: 0.2)

      assert_receive {:request_body, %{"temperature" => 0.2}}
    end

    test "omits temperature when not passed" do
      test_pid = self()

      Req.Test.stub(OpenAI, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(body)})
        Req.Test.json(conn, success_body())
      end)

      assert {:ok, _} = OpenAI.complete(@default_messages, @default_model)

      assert_receive {:request_body, body}
      refute Map.has_key?(body, "temperature")
    end

    test "sends Bearer auth header from config" do
      test_pid = self()

      Req.Test.stub(OpenAI, fn conn ->
        auth =
          conn
          |> Plug.Conn.get_req_header("authorization")
          |> List.first()

        send(test_pid, {:auth, auth})
        Req.Test.json(conn, success_body())
      end)

      assert {:ok, _} = OpenAI.complete(@default_messages, @default_model)
      assert_receive {:auth, "Bearer test-key-not-real"}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp success_body do
    %{
      "output" => [
        %{
          "status" => "completed",
          "content" => [%{"text" => "ok"}]
        }
      ],
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2},
      "model" => "gpt-4o"
    }
  end
end
