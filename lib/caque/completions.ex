defmodule Caque.Completions do
  @moduledoc """
  Calls out to external LLM APIs to generate text completions.
  Different APIs may require or return data having different shapes, so Completions defines bespoke functions for each API.
  """

  @doc """
  Generate a completion using the specified provider.

  ## Parameters
    - provider: The API provider (:anthropic or :openai)
    - context_docs: List of relevant documents retrieved from search
    - question: The user's question
    - model: The model identifier (e.g., "claude-3-5-sonnet-20241022", "gpt-4")

  ## Returns
    - {:ok, %{completion: text, usage: usage_info}}
    - {:error, reason}
  """
  def complete(:anthropic, _context_docs, _question, _model) do
    # TODO: Implement Anthropic Messages API call
    # - Munge context_docs into system/user messages
    # - Call Anthropic API
    # - Extract completion text and usage info
    {:error, :not_implemented}
  end

  def complete(:openai, context_docs, question, model) do
        [openai_key: api_key, completion_url: completion_url] = Application.get_env(:caque, __MODULE__)
        # Format context documents into a system message
    context_text =
    context_docs
    |> Enum.map(fn %{source: %{"package" => package, "source" => _source, "text" => text, "title" => title}} -> "From #{package}, this function is #{title} \n \n #{text}"  end)
    |> Enum.join()
            

    system_message = """
    You are a helpful assistant. Use the following context to answer the user's question.
    If the answer cannot be found in the context, say so.

    Context:
    #{context_text}
    """

                    messages = [
      %{role: "system", content: system_message},
      %{role: "user", content: question}
    ]

    Req.post(
      url: completion_url,
      json: %{model: model, messages: messages},
      auth: {:bearer, api_key}
    )
    |> case do
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"choices" => choices, "usage" => usage}
       }} ->
        completion =
          choices
          |> List.first()
          |> get_in(["message", "content"])

        {:ok, %{completion: completion, usage: usage}}

      {:ok, %Req.Response{status: code, body: body}} ->
        {:error, "#{__MODULE__} Transport layer error: #{code}, body: #{inspect(body)}"}

      {:error, %{reason: reason}} ->
        {:error, "#{__MODULE__} Application layer error: #{reason}"}
    end
  end
end
