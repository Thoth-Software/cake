defmodule CakeWeb.ChatLivePropertyTest do
  @moduledoc """
  Properties of what the chat makes of an answer's `actions` and `warnings`
  (#419), whatever the `{:response_ready, _}` payload holds:

    * a source chip has a download arrow exactly when the answer carries a
      `:download` action for the chip's `source_ref`;
    * the warning notice counts the `{:hallucinated_citation, _}` warnings,
      has its general line exactly when there is a warning of another kind,
      and is absent exactly when there are no warnings.

  Each generated payload is broadcast to one mounted chat as one more
  answer. Example tests, and the wording, are in `CakeWeb.ChatLiveTest`.
  """

  use CakeWeb.ConnCase, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias Cake.Conversation.Events

  setup :register_and_log_in_user

  @source_refs ["books/a.pdf", "books/b.pdf", "books/c.pdf"]

  # Citations numbered 1..K, as `Cake.Responses` numbers them. Some have no
  # file behind them, and some share one.
  defp citations do
    gen all(source_refs <- list_of(member_of([nil | @source_refs]), max_length: 5)) do
      source_refs
      |> Enum.with_index(1)
      |> Enum.map(fn {source_ref, index} ->
        %{
          new_index: index,
          label: "Book #{index}, p. #{index}",
          preview: "preview #{index}",
          source_ref: source_ref
        }
      end)
    end
  end

  # Wider than what `Cake.Responses` derives today: an action of either
  # kind, for any file, cited or not, and possibly twice.
  defp actions do
    list_of(
      fixed_map(%{
        kind: member_of([:download, :external_link]),
        label: constant("An action"),
        source_ref: member_of(@source_refs)
      }),
      max_length: 5
    )
  end

  defp warnings do
    list_of(
      one_of([
        tuple({constant(:hallucinated_citation), integer(0..50)}),
        tuple({member_of([:something_else, :another_kind]), term()})
      ]),
      max_length: 6
    )
  end

  # Broadcasts one more answer to the view and returns the id of its
  # message. The broadcast is delivered before this returns, and the view
  # handles it before the next call to it.
  defp answer(view, payload) do
    assigns = :sys.get_state(view.pid).socket.assigns
    topic = assigns.convo_pid |> :sys.get_state() |> Map.fetch!(:id) |> Events.topic()

    Phoenix.PubSub.broadcast!(Cake.PubSub, topic, {:response_ready, payload})

    "msg-#{length(assigns.messages)}"
  end

  property "a chip has a download arrow exactly when a :download action has its source_ref",
           %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/chat")

    check all(citations <- citations(), actions <- actions()) do
      id =
        answer(view, %{
          response: "An answer.",
          citations: citations,
          actions: actions,
          warnings: []
        })

      downloadable = for %{kind: :download, source_ref: source_ref} <- actions, do: source_ref

      for citation <- citations do
        chip = "##{id}-source-#{citation.new_index}"

        assert has_element?(view, chip)

        assert has_element?(view, chip <> " a") == citation.source_ref in downloadable

        if citation.source_ref in downloadable do
          assert has_element?(view, ~s(#{chip} a[href="/books/download/#{citation.source_ref}"]))
        end
      end
    end
  end

  property "the notice counts the hallucinated citations and has a general line exactly for the rest",
           %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/chat")

    check all(warnings <- warnings()) do
      id = answer(view, %{response: "An answer.", citations: [], actions: [], warnings: warnings})

      hallucinated = Enum.count(warnings, &match?({:hallucinated_citation, _}, &1))
      other = length(warnings) - hallucinated

      assert has_element?(view, "##{id}-warning") == (warnings != [])
      assert has_element?(view, ~s(##{id}-warning[role="note"])) == (warnings != [])
      assert has_element?(view, "##{id}-warning-hallucinated") == hallucinated > 0
      assert has_element?(view, "##{id}-warning-other") == other > 0

      if hallucinated > 0 do
        noun =
          if hallucinated == 1,
            do: "bracketed reference matched",
            else: "bracketed references matched"

        assert has_element?(
                 view,
                 "##{id}-warning-hallucinated",
                 "#{hallucinated} #{noun}"
               )
      end
    end
  end
end
