defmodule Cake.Responses do
  @moduledoc """
  Post-generation processing for the conversation layer.

  Step 2 implementation: `process/3` consolidates the existing helpers
  (`build_citation_map/1` + `Cake.Citations.extract/2`) behind a single
  `Result`-returning entry point. Pipeline semantics (renumbering, text
  rewriting, actions, formatting) land in Step 3.
  """

  @behaviour Cake.Responses.Behaviour

  alias Cake.Citations
  alias Cake.Responses.Result

  @api_timeout 120_000

  @impl Cake.Responses.Behaviour
  @spec process(String.t(), Cake.Responses.Behaviour.indexed_chunks(), keyword()) :: Result.t()
  def process(raw_text, indexed_chunks, _opts \\ []) do
    chunk_map = build_citation_map(indexed_chunks)
    parsed_citations = Citations.extract(raw_text, chunk_map)

    citations =
      Enum.map(parsed_citations, fn c ->
        %{
          old_index: c.index,
          new_index: c.index,
          id: {c.source_file_path, c.chunk_index},
          label: c.book_title,
          preview: c.chunk_preview,
          source_ref: c.source_file_path,
          extras: %{
            book_title: c.book_title,
            page_number: c.page_number,
            section_title: c.section_title,
            chunk_index: c.chunk_index
          }
        }
      end)

    %Result{
      raw_text: raw_text,
      final_text: raw_text,
      chunk_map: chunk_map,
      citations: citations
    }
  end

  # --- Deprecated-for-Step-3/4 helpers below ---
  # These remain public until later steps replace the pipeline internals
  # (build_citation_map in Step 3) and extract query_llm_raw out to
  # Cake.Generation (Step 4). Do not add new callers.

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
