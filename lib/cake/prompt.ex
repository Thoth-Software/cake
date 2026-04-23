defmodule Cake.Prompt do
  @moduledoc """
  Prompt-building and prompt-engineering for the conversation layer.

  Receives scored chunks from Search, filters by relevance floor and chunk
  ceiling, assigns dense 1..N indices, formats chunks into a numbered context
  block, integrates conversation history, and returns the messages list for
  the LLM.
  """

  @type indexed_chunk :: {pos_integer(), Cake.Search.scored_result()}
  @type context_quality :: :good | :none
  @type message :: %{role: String.t(), content: String.t()}

  @spec prepare_context([Cake.Search.scored_result()], keyword()) ::
          {[indexed_chunk()], context_quality()}
  def prepare_context(_scored_chunks, _opts \\ []), do: {[], :none}

  @spec build([indexed_chunk()], String.t(), [String.t()], keyword()) :: [message()]
  def build(_indexed_chunks, _question, _history, _opts \\ []), do: []

  @spec history_messages([String.t()]) :: [message()]
  def history_messages(_history), do: []

  @spec format_chunk(indexed_chunk()) :: String.t()
  def format_chunk(_indexed_chunk), do: ""

  @spec system_message_with_context([String.t()]) :: String.t()
  def system_message_with_context(_formatted_chunks), do: ""

  @spec system_message_no_context() :: String.t()
  def system_message_no_context, do: ""
end
