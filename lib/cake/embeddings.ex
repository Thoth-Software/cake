defmodule Cake.Embeddings do
  @moduledoc """
  Calls out to an external API to get embeddings.
  Different APIs may require or return data having different shapes, so Embeddings defines bespoke functinos for each API we foresee using.

  We should look into an Embedding struct to be persisted to postgres with metadata
  """

  @behaviour Cake.Embeddings.Behaviour

  # This needs a spec defining the different error tuples it can return
  @impl Cake.Embeddings.Behaviour
  def embed(:openai, %{input: input} = payload, model) do
    config = Application.get_env(:cake, __MODULE__, [])
    api_key = Keyword.fetch!(config, :openai_key)
    url = Keyword.fetch!(config, :base_url)

    request_opts =
      maybe_put_plug(
        [url: url, json: %{model: model, input: input}, auth: {:bearer, api_key}],
        config
      )

    # Later on, there should probably be multiple function heads of "embed", but
    # extract the following to its own re-used handle_response function.
    case Req.post(request_opts) do
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"data" => data, "usage" => usage}
       }} ->
        # Usage here refers to token usage. We really ought to store this in the
        # DB, maybe along with timestamps, service, embedding model used, and
        # then the actual embedding. All that implies an Embedding struct with
        # its own table. This, in turn, requires that we make embeddings into an
        # association instead of a field on the ParsedDocument struct.
        embedding =
          data
          |> Enum.find(fn item -> is_map(item) end)
          |> Map.get("embedding")

        attrs = %{embedding: embedding}

        # Thread the caller-provided struct back through untouched: the
        # Documents pipeline passes the ParsedDocument it is embedding and reads
        # it back to persist the embedding. Callers that pass no struct (Books)
        # get nil and ignore it.
        {:ok, %{usage: usage, struct: Map.get(payload, :struct), attrs: attrs}}

      {:ok, %Req.Response{status: code}} ->
        {:error, "#{__MODULE__}  Transport layer error: #{code}"}

      {:error, %{reason: reason}} ->
        {:error, "#{__MODULE__}  Application layer error: #{reason}"}
    end
  end

  # A `:plug` key in the config (set only in config/test.exs) routes HTTP through
  # Req.Test for stubbed responses, mirroring Cake.Generation.OpenAI. Production
  # config omits it.
  defp maybe_put_plug(opts, config) do
    case Keyword.get(config, :plug) do
      nil -> opts
      plug -> Keyword.put(opts, :plug, plug)
    end
  end
end

# SAMPLE OPENAI REQUEST
# curl https://api.openai.com/v1/embeddings \
#   -H "Authorization: Bearer $OPENAI_API_KEY" \
#   -H "Content-Type: application/json" \
#   -d '{
#     "input": "The food was delicious and the waiter...",
#     "model": "text-embedding-ada-002",
#     "encoding_format": "float"
#   }'

# SAMPLE OPENAI RESPONSE
# {
#   "object": "list",
#   "data": [
#     {
#       "object": "embedding",
#       "embedding": [
#         0.0023064255,
#         -0.009327292,
#         .... (1536 floats total for ada-002)
#         -0.0028842222,
#       ],
#       "index": 0
#     }
#   ],
#   "model": "text-embedding-ada-002",
#   "usage": {
#     "prompt_tokens": 8,
#     "total_tokens": 8
#   }
# }
