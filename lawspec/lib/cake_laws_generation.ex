# User-owned LawSpec adapter for laws/generation.lawspec.
defmodule Cake.Laws.Generation do
  @moduledoc """
  The native handlers of the `cake.laws.generation` unit's two abilities.

  `generation_handler/0` is `Cake.Generation.OpenAI`: `complete/3` and
  `complete_json/3` behind LawSpec's `Generation` interface, with the
  generated messages, model and schema turned into Cake's and the result
  turned back. It repairs nothing. A count, a finish reason or parsed JSON
  that breaks the contract reaches the laws as it left Cake.

  `provider_handler/0` is the OpenAI Responses API as a `Req.Test` plug.
  `Cake.Generation.OpenAI` reads its `:plug` from application config
  (`test/test_helper.exs` points it at `provider_plug/1`), and `will_reply`
  queues the reply the plug serves to the next request: a draft completion as
  a 200 body, as close to the wire as the draft allows, and a failure as the
  status or transport error Cake reports it from. The queue lives in the
  process dictionary, because Req runs a plug in the process that makes the
  request, and that is the process the law runs in.

  Requests are made with `max_retries: 0`. `Cake.Generation.OpenAI` retries a
  transport error, a 429 and a 5xx with Req's backoff, and the laws would
  wait seconds for each.
  """

  alias Cake.Generation.OpenAI
  alias Cake.Laws.Quiet
  alias LawSpec.Abilities.Cake.Laws.Generation.Generation
  alias LawSpec.Abilities.Cake.Laws.Generation.Provider
  alias LawSpec.Data

  @queue {__MODULE__, :replies}

  @doc "The provider: queues the replies `provider_plug/1` serves."
  @spec provider_handler() :: Provider.t()
  def provider_handler do
    Process.put(@queue, [])

    %Provider{
      will_reply: fn reply ->
        Process.put(@queue, Process.get(@queue, []) ++ [reply])
        :ok
      end
    }
  end

  @doc "`Cake.Generation.OpenAI` as the `Generation` ability's handler."
  @spec generation_handler() :: Generation.t()
  def generation_handler do
    %Generation{
      complete: fn messages, model ->
        fn -> OpenAI.complete(to_messages(messages), model, max_retries: 0) end
        |> Quiet.quietly()
        |> to_either(&to_completion/1)
      end,
      complete_json: fn messages, model, schema ->
        fn ->
          OpenAI.complete_json(to_messages(messages), model,
            schema: to_schema(schema),
            max_retries: 0
          )
        end
        |> Quiet.quietly()
        |> to_either(&to_json_completion/1)
      end
    }
  end

  @doc """
  The Responses API as a plug: answers with the oldest queued reply, and with
  a 503 when none is left.
  """
  @spec provider_plug(Plug.Conn.t()) :: Plug.Conn.t()
  def provider_plug(conn) do
    case Process.get(@queue, []) do
      [] ->
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "no reply queued"})

      [reply | rest] ->
        Process.put(@queue, rest)
        serve(conn, reply)
    end
  end

  # ---------------------------------------------------------------------------
  # The provider's wire
  # ---------------------------------------------------------------------------

  defp serve(conn, %Data.ReplyCompletes{value: draft}), do: serve_draft(conn, draft, draft.text)

  defp serve(conn, %Data.ReplyCompletesJson{value: json}),
    do: serve_draft(conn, json.completion, Jason.encode!(json_of(json.parsed)))

  defp serve(conn, %Data.ReplyErrors{value: error}), do: serve_error(conn, error)

  defp serve_draft(conn, %Data.Completion{} = draft, text) do
    Req.Test.json(conn, %{
      "output" => [
        Map.merge(
          %{"type" => "message", "role" => "assistant"},
          Map.put(block_status(draft.finish_reason), "content", [
            %{"type" => "output_text", "text" => text}
          ])
        )
      ],
      "usage" => %{
        "input_tokens" => draft.usage.input_tokens,
        "output_tokens" => draft.usage.output_tokens,
        "total_tokens" => draft.usage.total_tokens
      },
      "model" => draft.model
    })
  end

  # A message block's status is all the Responses API says of why it ended.
  defp block_status(%Data.FinishReasonStop{}), do: %{"status" => "completed"}
  defp block_status(%Data.FinishReasonToolUse{}), do: %{"status" => "completed"}
  defp block_status(%Data.FinishReasonLength{}), do: %{"status" => "incomplete"}

  defp block_status(%Data.FinishReasonContentFilter{}),
    do: %{"status" => "incomplete", "incomplete_details" => %{"reason" => "content_filter"}}

  defp block_status(%Data.FinishReasonUndocumented{value: name}), do: %{"status" => name}

  defp json_of(%Data.ParsedDecomposed{value: json}) do
    %{}
    |> put_present("atomic", json.atomic)
    |> put_present("sub_questions", json.sub_questions)
  end

  defp json_of(%Data.ParsedStepped{value: json}) do
    %{"reasoning" => json.reasoning, "retrieval_query" => from_maybe(json.retrieval_query)}
  end

  defp json_of(%Data.ParsedUnrecognised{}), do: %{"unrecognised" => true}

  defp put_present(map, _key, :absent), do: map
  defp put_present(map, key, {:present, value}), do: Map.put(map, key, value)

  defp serve_error(conn, %Data.GenerationErrorTransport{}),
    do: Req.Test.transport_error(conn, :econnrefused)

  defp serve_error(conn, %Data.GenerationErrorTimeout{}),
    do: Req.Test.transport_error(conn, :timeout)

  defp serve_error(conn, %Data.GenerationErrorRateLimited{value: retry_after}) do
    conn
    |> put_retry_after(retry_after)
    |> Plug.Conn.put_status(429)
    |> Req.Test.json(%{"error" => "rate limited"})
  end

  defp serve_error(conn, %Data.GenerationErrorAuth{value: message}),
    do: conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => message})

  defp serve_error(conn, %Data.GenerationErrorHttp{value: status}),
    do: conn |> Plug.Conn.put_status(http_status(status)) |> Req.Test.json(%{"error" => "http"})

  defp serve_error(conn, %Data.GenerationErrorMalformedResponse{}),
    do: Req.Test.json(conn, %{"unexpected" => true})

  defp serve_error(conn, %Data.GenerationErrorEmptyResponse{}) do
    Req.Test.json(conn, %{
      "output" => [%{"status" => "completed", "content" => [%{"text" => ""}]}],
      "usage" => %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0}
    })
  end

  # A provider has no wire form for the remaining reasons: malformed JSON is
  # the client's verdict on a 200, and Cake.Generation.OpenAI reports neither
  # a content filter nor a provider error. The provider refuses the request.
  defp serve_error(conn, _error),
    do: conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "refused"})

  defp put_retry_after(conn, :absent), do: conn

  defp put_retry_after(conn, {:present, seconds}),
    do: Plug.Conn.put_resp_header(conn, "retry-after", Integer.to_string(seconds))

  # Any generated status, folded into the 4xx and 5xx range.
  defp http_status(status), do: 400 + rem(status, 200)

  # ---------------------------------------------------------------------------
  # LawSpec's data to Cake's and back
  # ---------------------------------------------------------------------------

  defp to_messages(messages) do
    Enum.map(messages, fn %Data.Message{role: role, content: content} ->
      %{role: role_name(role), content: content}
    end)
  end

  defp role_name(%Data.RoleSystem{}), do: "system"
  defp role_name(%Data.RoleUser{}), do: "user"
  defp role_name(%Data.RoleAssistant{}), do: "assistant"

  defp to_schema(%Data.SchemaDecompositionSchema{}), do: Cake.Decomposition.LLM.schema()
  defp to_schema(%Data.SchemaIrcotSchema{}), do: Cake.Prompt.ircot_schema()

  defp to_either({:ok, value}, convert), do: {:right, convert.(value)}
  defp to_either({:error, reason}, _convert), do: {:left, to_error(reason)}

  defp to_completion(%{text: text, finish_reason: reason, usage: usage, model: model}) do
    %Data.Completion{
      text: text,
      finish_reason: to_finish_reason(reason),
      usage: %Data.Usage{
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        total_tokens: usage.total_tokens
      },
      model: model
    }
  end

  defp to_json_completion(%{parsed: parsed} = completion) do
    %Data.JsonCompletion{completion: to_completion(completion), parsed: to_parsed(parsed)}
  end

  defp to_finish_reason(:stop), do: %Data.FinishReasonStop{}
  defp to_finish_reason(:length), do: %Data.FinishReasonLength{}
  defp to_finish_reason(:content_filter), do: %Data.FinishReasonContentFilter{}
  defp to_finish_reason(:tool_use), do: %Data.FinishReasonToolUse{}
  defp to_finish_reason(other), do: %Data.FinishReasonUndocumented{value: inspect(other)}

  # The shape is read off the decoded JSON itself, not taken from the schema
  # that was asked for or from Cake's validator, so the law that compares the
  # two checks Cake's validation instead of repeating it.
  defp to_parsed(%{"reasoning" => reasoning, "retrieval_query" => query} = parsed)
       when map_size(parsed) == 2 and is_binary(reasoning) and (is_binary(query) or is_nil(query)) do
    %Data.ParsedStepped{
      value: %Data.IrcotJson{reasoning: reasoning, retrieval_query: to_maybe(query)}
    }
  end

  defp to_parsed(parsed) when is_map(parsed) do
    with [] <- Map.keys(parsed) -- ["atomic", "sub_questions"],
         {:ok, atomic} <- optional(parsed, "atomic", &is_boolean/1),
         {:ok, sub_questions} <- optional(parsed, "sub_questions", &strings?/1) do
      %Data.ParsedDecomposed{
        value: %Data.DecompositionJson{atomic: atomic, sub_questions: sub_questions}
      }
    else
      _ -> %Data.ParsedUnrecognised{}
    end
  end

  defp to_parsed(_parsed), do: %Data.ParsedUnrecognised{}

  defp optional(map, key, valid?) do
    case Map.fetch(map, key) do
      :error -> {:ok, :absent}
      {:ok, value} -> if valid?.(value), do: {:ok, {:present, value}}, else: :error
    end
  end

  defp strings?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)

  defp to_error({:transport, _reason}), do: %Data.GenerationErrorTransport{}
  defp to_error({:timeout, ms}), do: %Data.GenerationErrorTimeout{value: ms}

  defp to_error({:rate_limited, retry_after}),
    do: %Data.GenerationErrorRateLimited{value: to_maybe(retry_after)}

  defp to_error({:auth, message}), do: %Data.GenerationErrorAuth{value: message}
  defp to_error({:http, status, _body}), do: %Data.GenerationErrorHttp{value: status}

  defp to_error({:malformed_response, description, _body}),
    do: %Data.GenerationErrorMalformedResponse{value: description}

  defp to_error({:malformed_json, description, _body}),
    do: %Data.GenerationErrorMalformedJson{value: description}

  defp to_error({:empty_response, _body}), do: %Data.GenerationErrorEmptyResponse{}
  defp to_error({:content_filtered, _reason}), do: %Data.GenerationErrorContentFiltered{}

  defp to_error({:provider_error, message}),
    do: %Data.GenerationErrorProviderError{value: message}

  defp to_maybe(nil), do: :absent
  defp to_maybe(value), do: {:present, value}

  defp from_maybe(:absent), do: nil
  defp from_maybe({:present, value}), do: value
end
