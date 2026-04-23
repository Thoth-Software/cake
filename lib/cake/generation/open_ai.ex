defmodule Cake.Generation.OpenAI do
  @moduledoc """
  OpenAI implementation of the `Cake.Generation` behaviour.

  Uses the OpenAI Responses API. Handles transport-layer retries via Req's
  `:transient` policy (5xx and network blips get retried automatically;
  rate-limit, auth, and content-filter errors do not). Normalizes OpenAI's
  response shape into `Cake.Generation.completion/0` and translates provider
  errors into the taxonomy defined in `Cake.Generation.error_reason/0`.

  ## Configuration

      config :cake, #{inspect(__MODULE__)},
        openai_key: System.fetch_env!("OPENAI_API_KEY"),
        response_url: "https://api.openai.com/v1/responses"

  A `:plug` key can be added to the config (typically only in `config/test.exs`)
  to route HTTP through `Req.Test` for stubbed responses. Production config
  should omit it.
  """

  @behaviour Cake.Generation

  require Logger

  @default_timeout 60_000
  @default_max_retries 3

  @impl Cake.Generation
  @spec complete(Cake.Generation.messages(), Cake.Generation.model(), keyword()) ::
          {:ok, Cake.Generation.completion()} | {:error, Cake.Generation.error_reason()}
  def complete(messages, model, opts \\ []) do
    config = Application.get_env(:cake, __MODULE__, [])
    api_key = Keyword.fetch!(config, :openai_key)
    url = Keyword.fetch!(config, :response_url)

    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    started_at = System.monotonic_time(:millisecond)

    request_opts =
      maybe_put_plug(
        [
          url: url,
          json: build_body(messages, model, opts),
          auth: {:bearer, api_key},
          receive_timeout: timeout,
          retry: :transient,
          max_retries: max_retries
        ],
        config
      )

    result =
      request_opts
      |> Req.new()
      |> Req.post()
      |> handle_response(timeout)

    log_result(result, model, started_at)
    result
  end

  # ---------------------------------------------------------------------------
  # Request construction
  # ---------------------------------------------------------------------------

  defp build_body(messages, model, opts) do
    base = %{model: model, input: messages}

    case Keyword.get(opts, :temperature) do
      nil -> base
      temperature -> Map.put(base, :temperature, temperature)
    end
  end

  defp maybe_put_plug(opts, config) do
    case Keyword.get(config, :plug) do
      nil -> opts
      plug -> Keyword.put(opts, :plug, plug)
    end
  end

  # ---------------------------------------------------------------------------
  # Response handling — one clause per outcome
  # ---------------------------------------------------------------------------

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}, _timeout),
    do: parse_success(body)

  defp handle_response({:ok, %Req.Response{status: 401, body: body}}, _timeout),
    do: {:error, {:auth, inspect(body)}}

  defp handle_response({:ok, %Req.Response{status: 429} = response}, _timeout) do
    retry_after =
      response
      |> Req.Response.get_header("retry-after")
      |> List.first()
      |> parse_retry_after()

    {:error, {:rate_limited, retry_after}}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, _timeout),
    do: {:error, {:http, status, body}}

  defp handle_response({:error, %Req.TransportError{reason: :timeout}}, timeout),
    do: {:error, {:timeout, timeout}}

  defp handle_response({:error, %Req.TransportError{reason: reason}}, _timeout),
    do: {:error, {:transport, reason}}

  defp handle_response({:error, reason}, _timeout),
    do: {:error, {:transport, reason}}

  # ---------------------------------------------------------------------------
  # Success body parsing
  # ---------------------------------------------------------------------------

  defp parse_success(%{"output" => output, "usage" => usage} = body) do
    with {:ok, text, finish_reason} <- extract_content(output) do
      {:ok,
       %{
         text: text,
         finish_reason: finish_reason,
         usage: normalize_usage(usage),
         model: Map.get(body, "model", "unknown")
       }}
    end
  end

  defp parse_success(body) when is_map(body) and is_map_key(body, "output"),
    do: {:error, {:malformed_response, "missing usage key", body}}

  defp parse_success(body),
    do: {:error, {:malformed_response, "missing output key", body}}

  defp extract_content(output) when is_list(output) do
    case Enum.find(output, &content_item?/1) do
      nil ->
        {:error, {:malformed_response, "no content block in output", output}}

      %{"content" => [%{"text" => ""} | _]} = block ->
        {:error, {:empty_response, block}}

      %{"content" => [%{"text" => text} | _], "status" => "completed"} ->
        {:ok, text, :stop}

      %{"content" => [%{"text" => text} | _], "status" => "incomplete"} ->
        {:ok, text, :length}

      %{"content" => [%{"text" => text} | _]} ->
        {:ok, text, :stop}

      other ->
        {:error, {:malformed_response, "unexpected content structure", other}}
    end
  end

  defp extract_content(output),
    do: {:error, {:malformed_response, "output is not a list", output}}

  defp content_item?(item) when is_map(item), do: Map.has_key?(item, "content")
  defp content_item?(_), do: false

  # ---------------------------------------------------------------------------
  # Usage normalization — handles Responses API and legacy Chat Completions shapes
  # ---------------------------------------------------------------------------

  defp normalize_usage(%{"input_tokens" => i, "output_tokens" => o, "total_tokens" => t}),
    do: %{input_tokens: i, output_tokens: o, total_tokens: t}

  defp normalize_usage(%{"prompt_tokens" => i, "completion_tokens" => o, "total_tokens" => t}),
    do: %{input_tokens: i, output_tokens: o, total_tokens: t}

  defp normalize_usage(_),
    do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

  # ---------------------------------------------------------------------------
  # Header parsing
  # ---------------------------------------------------------------------------

  defp parse_retry_after(nil), do: nil

  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_retry_after(_), do: nil

  # ---------------------------------------------------------------------------
  # Logging
  # ---------------------------------------------------------------------------

  defp log_result({:ok, %{usage: u, finish_reason: fr}}, model, started_at) do
    elapsed = System.monotonic_time(:millisecond) - started_at

    Logger.info(
      "#{__MODULE__} model=#{model} tokens_in=#{u.input_tokens} " <>
        "tokens_out=#{u.output_tokens} finish=#{fr} elapsed_ms=#{elapsed}"
    )
  end

  defp log_result({:error, reason}, model, started_at) do
    elapsed = System.monotonic_time(:millisecond) - started_at

    Logger.warning(
      "#{__MODULE__} model=#{model} elapsed_ms=#{elapsed} error=#{inspect(reason)}"
    )
  end
end
