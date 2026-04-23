defmodule Cake.Generation do
  @moduledoc """
  Behaviour contract for LLM text generation services.

  The real implementations are `Cake.Generation.OpenAI` and
  `Cake.Generation.Anthropic`. In tests: `Cake.Generation.Mock` (Mox).

  Callers receive the implementation module as an injected argument,
  following the same pattern as `cluster` and `search` in Conversation.

  Implementations are responsible for:
    - HTTP transport to the LLM provider
    - Timeout and transport-layer retry policy
    - Normalizing provider-specific response shapes to `t:completion/0`
    - Translating provider-specific errors into `t:error_reason/0`

  ## TODO: LLM-specific failure modes to address post-demo

    - Truncated responses (`finish_reason: :length`): expose to caller,
      consider automatic continuation prompting.
    - Content filter refusals: currently surfaced as
      `{:error, {:content_filtered, _}}`; decide on user-facing messaging
      strategy in Conversation.
    - Empty completions: surfaced as `{:error, {:empty_response, _}}`;
      Conversation should treat as "no answer available" not a system error.
    - Rate-limit backoff: Conversation could implement exponential backoff
      on `{:error, {:rate_limited, _}}` instead of failing immediately.
    - Structured output validation: when JSON-mode is introduced, add a
      `:malformed_json` error variant.
  """

  @type message :: %{role: String.t(), content: String.t()}
  @type messages :: [message()]
  @type model :: String.t()

  @type usage :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer()
        }

  @typedoc """
  A successful completion.

  `:finish_reason` is normalized across providers:
    - `:stop` — model produced end-of-turn naturally
    - `:length` — hit max_tokens, response may be truncated
    - `:content_filter` — provider safety filter intervened
    - `:tool_use` — model requested a tool call (not currently used)
  """
  @type completion :: %{
          text: String.t(),
          finish_reason: :stop | :length | :content_filter | :tool_use,
          usage: usage(),
          model: model()
        }

  @typedoc """
  Normalized error reasons. Keeps the error space small and
  pattern-matchable so callers can decide handling without inspecting
  provider-specific error strings.
  """
  @type error_reason ::
          {:transport, term()}
          | {:timeout, non_neg_integer()}
          | {:rate_limited, retry_after :: non_neg_integer() | nil}
          | {:auth, String.t()}
          | {:http, status :: pos_integer(), body :: term()}
          | {:malformed_response, description :: String.t(), body :: term()}
          | {:empty_response, body :: term()}
          | {:content_filtered, reason :: term()}
          | {:provider_error, String.t()}

  @type complete_opts :: [
          timeout: non_neg_integer(),
          max_retries: non_neg_integer(),
          temperature: float()
        ]

  @doc """
  Send a messages list to the LLM and return the completed response.

  Implementations SHOULD handle transport-layer retries internally (transient
  network failures, 5xx responses) and SHOULD NOT retry on content-filter,
  auth, or malformed-response errors.
  """
  @callback complete(messages(), model(), complete_opts()) ::
              {:ok, completion()} | {:error, error_reason()}
end
