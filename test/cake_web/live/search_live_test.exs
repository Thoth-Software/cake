defmodule CakeWeb.SearchLiveTest do
  @moduledoc """
  Mount + render characterization tests for `CakeWeb.SearchLive`.

  Search-flow tests require a mock of `Cake.Embeddings.embed/3` and
  `Cake.Search.OpenSearch.search_chunks_with_context/5`. Those are
  deferred from this PR — see #112's description.
  """

  use CakeWeb.ConnCase

  import Mox
  import Phoenix.LiveViewTest

  setup :set_mox_from_context
  setup :verify_on_exit!

  describe "GET /search" do
    test "mounts and renders the search form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/search")

      assert html =~ "Cake Search"
      assert html =~ "Search books..."
      assert html =~ "Search"
    end

    test "starts with no results, no loading indicator, and no error", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/search")

      refute html =~ "Searching..."
      refute html =~ "relevant sections found"
    end

    test "ignores blank queries without crashing the LiveView", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/search")

      result =
        lv
        |> form("form", %{"query" => "   "})
        |> render_submit()

      refute result =~ "Searching..."
      assert render(lv) =~ "Cake Search"
    end
  end

  describe "configurable defaults" do
    test "passes configured embeddings_module, provider, and embedding model to embed/3",
         %{conn: conn} do
      Application.put_env(:cake, :embeddings_module, Cake.Embeddings.Mock)
      Application.put_env(:cake, :default_embedding_model, "test-embedder")
      Application.put_env(:cake, :default_provider, :test_provider)

      on_exit(fn ->
        Application.delete_env(:cake, :embeddings_module)
        Application.delete_env(:cake, :default_embedding_model)
        Application.delete_env(:cake, :default_provider)
      end)

      test_pid = self()

      expect(Cake.Embeddings.Mock, :embed, fn provider, input, model ->
        send(test_pid, {:embed_called, provider, input, model})
        {:error, :stop_here}
      end)

      {:ok, lv, _html} = live(conn, ~p"/search")

      lv
      |> form("form", %{"query" => "anything"})
      |> render_submit()

      assert_receive {:embed_called, :test_provider, %{input: "anything"}, "test-embedder"}, 1_000
    end
  end
end
