defmodule CakeWeb.SearchLiveTest do
  @moduledoc """
  Mount + render characterization tests for `CakeWeb.SearchLive`.

  Search-flow tests require a mock of `Cake.Embeddings.embed/3` and
  `Cake.Search.OpenSearch.search_chunks_with_context/5`. Those are
  deferred from this PR — see #112's description.
  """

  use CakeWeb.ConnCase

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  describe "authentication" do
    test "redirects to the login page when the user is not authenticated" do
      assert {:error, {:redirect, %{to: path}}} = live(build_conn(), ~p"/search")
      assert path =~ "/users/log_in"
    end
  end

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

  describe "error handling" do
    test "shows a generic message without leaking the internal error", %{conn: conn} do
      Application.put_env(:cake, Cake.Embeddings,
        openai_key: "test-key",
        base_url: "http://localhost/v1/embeddings",
        req_options: [plug: {Req.Test, Cake.Embeddings}]
      )

      on_exit(fn -> Application.delete_env(:cake, Cake.Embeddings) end)

      {:ok, lv, _} = live(conn, ~p"/search")

      Req.Test.stub(Cake.Embeddings, fn c -> Plug.Conn.send_resp(c, 500, "boom") end)
      Req.Test.allow(Cake.Embeddings, self(), lv.pid)

      html =
        lv
        |> form("form", %{"query" => "hello"})
        |> render_submit()

      refute html =~ "Transport layer error"
      assert html =~ "Search failed"
    end
  end
end
