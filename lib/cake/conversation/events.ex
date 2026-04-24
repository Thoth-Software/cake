defmodule Cake.Conversation.Events do
  @moduledoc """
  Broadcast payload shapes for Conversation's PubSub topic.

  Topic convention: `"conversation:\#{conversation_id}"`
  """

  @type response_ready :: {:response_ready, %{response: String.t(), citations: list(map())}}
  @type error :: {:error, reason :: term()}

  @type t :: response_ready() | error()

  @spec topic(String.t()) :: String.t()
  def topic(conversation_id), do: "conversation:#{conversation_id}"

  # Future events (Issue 4 — state machine):
  # - {:state_change, new_state}
  # - {:candidates_ready, grouped_candidates}
end
