defmodule Cake.Conversation.Events do
  @moduledoc """
  Broadcast payload shapes for Conversation's PubSub topic.

  Topic convention: `"conversation:\#{conversation_id}"`
  """

  @type response_ready :: {:response_ready, %{response: String.t(), citations: list(map())}}
  @type candidates_ready :: {:candidates_ready, candidates :: list()}
  @type state_change :: {:state_change, Cake.Conversation.State.state_name()}
  @type error :: {:error, reason :: term()}

  @type t :: response_ready() | candidates_ready() | state_change() | error()

  @spec topic(String.t()) :: String.t()
  def topic(conversation_id), do: "conversation:#{conversation_id}"
end
