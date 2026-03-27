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
  def query_llm(:anthropic, _context_docs, _question, _model) do
    # TODO: Implement Anthropic Messages API call
    # - Munge context_docs into system/user messages
    # - Call Anthropic API
    # - Extract response text and usage info
    {:error, :not_implemented}
  end

  def query_llm(:openai, context_docs, question, model) do
    [openai_key: api_key, response_url: response_url] = Application.get_env(:cake, __MODULE__)

    # Number each chunk and build context text with URLs
    numbered_chunks =
      context_docs
      |> Enum.with_index(1)
      |> Enum.map(fn {%{source: %{"package" => package, "text" => text, "title" => title, "url" => url}}, idx} ->
        {idx,
         """
         [#{idx}] Package: #{package} | Title: #{title}
         URL: #{url}

         #{text}\
         """}
      end)

    context_text = numbered_chunks |> Enum.map_join("\n---\n", fn {_idx, text} -> text end)

    # Build chunk_map: index -> metadata
    chunk_map =
      context_docs
      |> Enum.with_index(1)
      |> Map.new(fn {%{source: %{"package" => package, "title" => title, "url" => url}}, idx} ->
        {idx, %{package: package, title: title, url: url}}
      end)

    system_message = """
    You are a helpful assistant. Use the provided context to answer the user's question.
    When a claim draws from a specific chunk, cite it inline using the format [N] where N is the chunk number.
    If multiple chunks support a claim, cite all of them like [1][3].
    If the answer cannot be found in the context, say so.
    Do NOT fabricate citations. Only cite chunks that actually support the claim.

    Context:
    #{context_text}
    """

    messages = [
      %{role: "system", content: system_message},
      %{role: "user", content: question}
    ]

    Req.post(
      url: response_url,
      json: %{model: model, input: messages},
      auth: {:bearer, api_key},
      receive_timeout: @api_timeout
    )
    |> case do
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"output" => output, "usage" => usage}
       }} ->
        response =
          output
          |> Enum.find(fn map -> Map.has_key?(map, "content") end)
          |> Map.get("content")
          |> List.first()
          |> Map.get("text")

        {:ok, %{response: response, usage: usage, chunk_map: chunk_map}}

      {:ok, %Req.Response{status: code, body: body}} ->
        {:error, "in #{__MODULE__} \n #{code} error, body: #{inspect(body)}"}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, "#{__MODULE__} Transport error: #{reason}"}
    end
  end

  # def munge_document(%ParsedDocument{"package" => package, "source" => _source, "text" => text, "title" => title})
end
