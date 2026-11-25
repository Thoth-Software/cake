defmodule Cake.Conversation.Events do
  @moduledoc """
  Broadcast payload shapes for Conversation's PubSub topic.

  Topic convention: `"conversation:\#{conversation_id}"`
  """

  @typedoc """
  A finished turn, as `Cake.Responses` processed it: the final response text
  (`Cake.Responses.Result`'s `final_text`), its citations, the actions derived
  from them (one `:download` per cited file) and the warnings (a
  `{:hallucinated_citation, n}` for each `[n]` marker that named no chunk).
  All four keys are always present; a turn with nothing to download or to
  warn about carries empty lists.
  """
  @type response_ready ::
          {:response_ready,
           %{
             response: String.t(),
             citations: [Cake.Responses.Result.citation()],
             actions: [Cake.Responses.Result.action()],
             warnings: [Cake.Responses.Result.warning()]
           }}

  @typedoc "A manual turn's retrieved candidates, ready for the user to pick from."
  @type candidates_ready :: {:candidates_ready, candidates :: list()}

  @typedoc "The turn state machine moved to a new state."
  @type state_change :: {:state_change, Cake.Conversation.State.state_name()}

  @typedoc "A turn failed with the given reason."
  @type error :: {:error, reason :: term()}

  @typedoc "Any payload broadcast on a conversation's topic."
  @type t :: response_ready() | candidates_ready() | state_change() | error()

  @doc """
  The PubSub topic for one conversation: `"conversation:\#{conversation_id}"`.
  `Cake.Conversation` broadcasts every event here and `CakeWeb.ChatLive`
  subscribes to it.
  """
  @spec topic(String.t()) :: String.t()
  def topic(conversation_id), do: "conversation:#{conversation_id}"
end
