# User-owned support module, shared by the adapters (see lawspec/README.md).
defmodule Cake.Laws.HandlerGeneration do
  @moduledoc """
  A LawSpec `Generation` handler as a `Cake.Generation` module.

  Cake code takes its generation collaborator as a module and calls
  `generation.complete_json(messages, model, opts)` on it. An adapter whose
  signature ends `uses Generation` is handed a struct of functions instead
  (`LawSpec.Abilities.Cake.Laws.Generation.Generation`). This module is the
  bridge: `with_handler/2` installs the struct for the calling process, and
  inside it `Cake.Laws.HandlerGeneration` is a `Cake.Generation`
  implementation that asks the struct.

      HandlerGeneration.with_handler(handler, fn ->
        Cake.Decomposition.LLM.decompose(question, generation: HandlerGeneration)
      end)

  The handler is kept in the process dictionary, so the Cake code must call
  the generation module in the process that called `with_handler/2`.

  It translates and repairs nothing. Messages, the model and the schema reach
  the handler as Cake sent them, and what the handler answers reaches Cake as
  the handler gave it, in the shapes `Cake.Generation` documents. LawSpec's
  failures leave out the response bodies and other terms Cake's carry
  (`cake.laws.generation`, `GenerationError`), so those come back as `nil`;
  `Cake.Laws.Generation.to_error/1` is the way back, and the two are
  inverses on every LawSpec failure.

  A schema that is neither of the two Cake sends
  (`Cake.Decomposition.LLM.schema/0`, `Cake.Prompt.ircot_schema/0`) has no
  LawSpec `Schema`, and neither has a message that is not exactly a role and
  its content. Both raise, so a law that reaches one fails.
  """

  @behaviour Cake.Generation

  alias LawSpec.Abilities.Cake.Laws.Generation.Generation
  alias LawSpec.Data

  @handler {__MODULE__, :handler}

  @doc """
  Calls `fun` with `handler` answering this module's `Cake.Generation`
  callbacks in the calling process, and returns what `fun` returned. The
  handler installed before the call, if any, is back in place afterwards,
  whether `fun` returns or raises.
  """
  @spec with_handler(Generation.t(), (-> result)) :: result when result: var
  def with_handler(%Generation{} = handler, fun) when is_function(fun, 0) do
    previous = Process.put(@handler, handler)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  @impl Cake.Generation
  @spec complete(Cake.Generation.messages(), Cake.Generation.model(), keyword()) ::
          {:ok, Cake.Generation.completion()} | {:error, Cake.Generation.error_reason()}
  def complete(messages, model, _opts) when is_list(messages) and is_binary(model) do
    handler!().complete.(to_messages(messages), model)
    |> from_either(&from_completion/1)
  end

  @impl Cake.Generation
  @spec complete_json(Cake.Generation.messages(), Cake.Generation.model(), keyword()) ::
          {:ok, Cake.Generation.json_completion()} | {:error, Cake.Generation.error_reason()}
  def complete_json(messages, model, opts) when is_list(messages) and is_binary(model) do
    schema = opts |> Keyword.fetch!(:schema) |> to_schema()

    handler!().complete_json.(to_messages(messages), model, schema)
    |> from_either(&from_json_completion/1)
  end

  @doc """
  Cake's messages as LawSpec's. Public so an adapter can give a law the
  messages Cake builds (`Cake.Prompt.decomposition_prompt/1`, say) in the
  form a recorded call holds them.
  """
  @spec to_messages(Cake.Generation.messages()) :: [Data.message()]
  def to_messages(messages) when is_list(messages), do: Enum.map(messages, &to_message/1)

  defp to_message(%{role: role, content: content} = message)
       when map_size(message) == 2 and is_binary(content) do
    %Data.Message{role: to_role(role), content: content}
  end

  defp to_message(message) do
    raise "a message LawSpec's Message cannot hold: #{inspect(message)}"
  end

  defp to_role("system"), do: %Data.RoleSystem{}
  defp to_role("user"), do: %Data.RoleUser{}
  defp to_role("assistant"), do: %Data.RoleAssistant{}
  defp to_role(role), do: raise("a role LawSpec's Role cannot hold: #{inspect(role)}")

  # Compared with the schemas Cake's own modules return, so a caller that
  # sends a copy which has drifted from them raises here.
  defp to_schema(schema) do
    cond do
      schema == Cake.Decomposition.LLM.schema() -> %Data.SchemaDecompositionSchema{}
      schema == Cake.Prompt.ircot_schema() -> %Data.SchemaIrcotSchema{}
      true -> raise "a schema Cake does not send: #{inspect(schema)}"
    end
  end

  defp handler! do
    case Process.get(@handler) do
      %Generation{} = handler -> handler
      nil -> raise "#{inspect(__MODULE__)} was called outside with_handler/2"
    end
  end

  defp restore(nil), do: Process.delete(@handler)
  defp restore(%Generation{} = previous), do: Process.put(@handler, previous)

  # ---------------------------------------------------------------------------
  # LawSpec's answers as Cake's
  # ---------------------------------------------------------------------------

  defp from_either({:right, value}, convert), do: {:ok, convert.(value)}
  defp from_either({:left, error}, _convert), do: {:error, from_error(error)}

  defp from_completion(%Data.Completion{} = completion) do
    %{
      text: completion.text,
      finish_reason: from_finish_reason(completion.finish_reason),
      usage: %{
        input_tokens: completion.usage.input_tokens,
        output_tokens: completion.usage.output_tokens,
        total_tokens: completion.usage.total_tokens
      },
      model: completion.model
    }
  end

  defp from_json_completion(%Data.JsonCompletion{completion: completion, parsed: parsed}) do
    completion
    |> from_completion()
    |> Map.put(:parsed, Cake.Laws.Generation.json_of(parsed))
  end

  defp from_finish_reason(%Data.FinishReasonStop{}), do: :stop
  defp from_finish_reason(%Data.FinishReasonLength{}), do: :length
  defp from_finish_reason(%Data.FinishReasonContentFilter{}), do: :content_filter
  defp from_finish_reason(%Data.FinishReasonToolUse{}), do: :tool_use
  # No lawful handler succeeds with this one. It is passed on as it is, not
  # turned into an atom the contract documents.
  defp from_finish_reason(%Data.FinishReasonUndocumented{value: name}), do: {:undocumented, name}

  defp from_error(%Data.GenerationErrorTransport{}), do: {:transport, :lawspec_handler}
  defp from_error(%Data.GenerationErrorTimeout{value: ms}), do: {:timeout, ms}

  defp from_error(%Data.GenerationErrorRateLimited{value: retry_after}),
    do: {:rate_limited, from_maybe(retry_after)}

  defp from_error(%Data.GenerationErrorAuth{value: message}), do: {:auth, message}
  defp from_error(%Data.GenerationErrorHttp{value: status}), do: {:http, status, nil}

  defp from_error(%Data.GenerationErrorMalformedResponse{value: description}),
    do: {:malformed_response, description, nil}

  defp from_error(%Data.GenerationErrorMalformedJson{value: description}),
    do: {:malformed_json, description, nil}

  defp from_error(%Data.GenerationErrorEmptyResponse{}), do: {:empty_response, nil}
  defp from_error(%Data.GenerationErrorContentFiltered{}), do: {:content_filtered, nil}

  defp from_error(%Data.GenerationErrorProviderError{value: message}),
    do: {:provider_error, message}

  defp from_maybe(:absent), do: nil
  defp from_maybe({:present, value}), do: value
end
