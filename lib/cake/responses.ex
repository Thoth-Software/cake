defmodule Cake.Responses do
  @moduledoc """
  Calls out to external LLM APIs to generate text responses.
  Different APIs may require or return data having different shapes, so Responses defines bespoke functions for each API.
  """

  @api_timeout 120_000

  @doc """
  Generate a response using the specified provider.

  ## Parameters
    - provider: The API provider (:anthropic or :openai)
    - context_docs: List of relevant documents retrieved from search
    - question: The user's question
    - model: The model identifier (e.g., "claude-3-5-sonnet-20241022", "gpt-4")

  ## Returns
    - {:ok, %{response: text, usage: usage_info}}
    - {:error, reason}
  """
  @spec query_llm(atom(), list(), String.t(), String.t()) :: {:ok, map()} | {:error, any()}
  def query_llm(:anthropic, _context_docs, _question, _model) do
    # TODO: Implement Anthropic Messages API call
    # - Munge context_docs into system/user messages
    # - Call Anthropic API
    # - Extract response text and usage info
    {:error, :not_implemented}
  end

  # NOTE: right now this is keyed to the Chunk generic for chunks of ingested
  # books. We need to re-think the architecture around this. In particular, we
  # need to set up this module so it can be agnostic about what particular struct
  # is being passed in. The solution for this should probably mirror the
  # solution we've architected for the search function in the Cluster module,
  # but with protocols rather than behaviours

  def query_llm(:openai, context_docs, question, model) do
    [openai_key: api_key, response_url: response_url] = Application.get_env(:cake, __MODULE__)

    # Build chunk_map: index -> metadata
    chunks = build_chunk_map(context_docs)
    message = system_message(chunks)

    messages = [
      %{role: "system", content: message},
      %{role: "user", content: question}
    ]

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
    |> handle_response(chunks)
  end

  defp handle_response(
         {:ok, %Req.Response{status: 200, body: %{"output" => output, "usage" => usage}}},
         chunks
       ) do
    case Enum.find(output, fn map -> Map.has_key?(map, "content") end) do
      %{"content" => [%{"text" => text} | _]} ->
        {:ok, %{response: text, usage: usage, chunk_map: chunks}}

      nil ->
        {:error, "#{__MODULE__}: no content block found in output: #{inspect(output)}"}

      other ->
        {:error, "#{__MODULE__}: unexpected content structure: #{inspect(other)}"}
    end
  end

  defp handle_response({:ok, %Req.Response{status: code, body: body}}, _chunks) do
    {:error, "in #{__MODULE__} \n #{code} error, body: #{inspect(body)}"}
  end

  defp handle_response({:error, %Req.TransportError{reason: reason}}, _chunks) do
    {:error, "#{__MODULE__} Transport error: #{reason}"}
  end

  defp build_chunk_map(context_docs) do
    context_docs
    |> Enum.with_index(1)
    |> Map.new(fn {%Cake.Books.Chunk{
                     text: text,
                     section_title: section_title,
                     page_number: page_number,
                     chunk_index: chunk_index,
                     parsed_book: %{title: book_title, source_file_path: source_file_path}
                   }, idx} ->
      {idx,
       """
       [#{idx}] Book: #{book_title} | Page: #{page_number}
       Section: #{section_title || "(none)"}

       #{text}\
       """,
       %{
         book_title: book_title,
         page_number: page_number,
         section_title: section_title,
         chunk_index: chunk_index,
         chunk_preview: String.slice(text, 0, 200),
         source_file_path: source_file_path
       }}
    end)
  end

  defp system_message(chunk_map) do
    context_text = Enum.map_join(chunk_map, "\n---\n", fn {_idx, text, _meta} -> text end)

    """
    You are a helpful assistant. Use the provided context to answer the user's question.
    Use inline citations like [1], [2] when drawing from a specific chunk. Each number corresponds to a numbered chunk above.
    If multiple chunks support a claim, cite all of them like [1][3].
    Prioritize citing specific page numbers when answering.
    If the answer cannot be found in the context, say so.
    Do NOT fabricate citations. Only cite chunks that actually support the claim.

    Context:
    #{context_text}
    """
  end
end
