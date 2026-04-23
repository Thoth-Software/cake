defmodule Cake.Responses do
  @moduledoc """
  Post-generation processing for the conversation layer.

  Builds citation metadata maps from indexed chunks, delegates citation
  parsing to Cake.Citations, and structures the final response for the
  frontend. Does not build prompts (see Cake.Prompt) or call the LLM
  (see Cake.Generation, future).
  """

  @api_timeout 120_000

  @spec build_citation_map(list({pos_integer(), {struct(), map()}})) :: map()
  def build_citation_map(indexed_chunks) do
    Map.new(indexed_chunks, fn {idx, {chunk, _scores}} ->
      # TODO: Generalize beyond Books.Chunk (mirrors search_fields/0 pattern)
      {idx,
       %{
         book_title: chunk.parsed_book.title,
         page_number: chunk.page_number,
         section_title: chunk.section_title,
         chunk_index: chunk.chunk_index,
         chunk_preview: String.slice(chunk.text, 0, 200),
         source_file_path: chunk.parsed_book.source_file_path
       }}
    end)
  end

  @spec query_llm_raw(atom(), list(), String.t()) :: {:ok, map()} | {:error, any()}
  def query_llm_raw(:anthropic, _messages, _model) do
    # TODO: Implement Anthropic Messages API call
    {:error, :not_implemented}
  end

  def query_llm_raw(:openai, messages, model) do
    [openai_key: api_key, response_url: response_url] = Application.get_env(:cake, __MODULE__)

    [
      url: response_url,
      json: %{model: model, input: messages},
      auth: {:bearer, api_key},
      receive_timeout: @api_timeout,
      retry: :transient,
      max_retries: 3
    ]
    |> Req.new()
    |> Req.post()
    |> handle_response()
  end

  defp handle_response(
         {:ok, %Req.Response{status: 200, body: %{"output" => output, "usage" => usage}}}
       ) do
    case Enum.find(output, fn map -> Map.has_key?(map, "content") end) do
      %{"content" => [%{"text" => text} | _]} ->
        {:ok, %{response: text, usage: usage}}

      nil ->
        {:error, "#{__MODULE__}: no content block found in output: #{inspect(output)}"}

      other ->
        {:error, "#{__MODULE__}: unexpected content structure: #{inspect(other)}"}
    end
  end

  defp handle_response({:ok, %Req.Response{status: code, body: body}}) do
    {:error, "in #{__MODULE__} \n #{code} error, body: #{inspect(body)}"}
  end

  defp handle_response({:error, %Req.TransportError{reason: reason}}) do
    {:error, "#{__MODULE__} Transport error: #{reason}"}
  end
end
