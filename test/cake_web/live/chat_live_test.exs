defmodule CakeWeb.ChatLiveTest do
  @moduledoc """
  Mount + render characterization tests for `CakeWeb.ChatLive`.

  Submit / response-flow / citation-display tests require an end-to-end
  mock of `Cake.Conversation` plus its `Cake.Search` and `Cake.Generation`
  collaborators. Those are deferred from this PR — see #112's description.
  """

  use CakeWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "GET /chat" do
    test "mounts and renders the chat surface", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/chat")

      assert html =~ "Cake Chat"
      assert html =~ "Ask a question..."
      assert html =~ "Send"
    end

    test "starts with no messages and the loading indicator hidden", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/chat")

      refute html =~ "Thinking..."
      refute html =~ "msg-0"
    end

    test "ignores blank submissions without crashing the LiveView", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/chat")

      result =
        lv
        |> form("form", %{"question" => "   "})
        |> render_submit()

      refute result =~ "Thinking..."
      assert render(lv) =~ "Cake Chat"
    end
  end

  describe "configurable defaults" do
    test "passes :default_embedding_model, :default_response_model, and :default_provider " <>
           "from application config to the spawned Conversation",
         %{conn: conn} do
      Application.put_env(:cake, :default_embedding_model, "test-embedder")
      Application.put_env(:cake, :default_response_model, "test-response-model")
      Application.put_env(:cake, :default_provider, :test_provider)

      on_exit(fn ->
        Application.delete_env(:cake, :default_embedding_model)
        Application.delete_env(:cake, :default_response_model)
        Application.delete_env(:cake, :default_provider)
      end)

      {:ok, lv, _html} = live(conn, ~p"/chat")

      convo_pid = :sys.get_state(lv.pid).socket.assigns.convo_pid
      convo_state = :sys.get_state(convo_pid)

      assert convo_state.embedder == "test-embedder"
      assert convo_state.response_model == "test-response-model"
      assert convo_state.provider == :test_provider
    end
  end
end
