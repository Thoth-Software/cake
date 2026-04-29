defmodule CakeWeb.SearchLiveTest do
  @moduledoc """
  Mount + render characterization tests for `CakeWeb.SearchLive`.

  Search-flow tests require a mock of `Cake.Embeddings.embed/3` and
  `Cake.Search.OpenSearch.search_chunks_with_context/5`. Those are
  deferred from this PR — see #112's description.
  """

  use CakeWeb.ConnCase

  import Phoenix.LiveViewTest

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
end
