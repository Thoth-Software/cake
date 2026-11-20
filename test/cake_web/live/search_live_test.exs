defmodule CakeWeb.SearchLiveTest do
  @moduledoc """
  Mount + render characterization tests for `CakeWeb.SearchLive`.

  Search-flow tests require a mock of `Cake.Embeddings.embed/3` and
  `Cake.Search.Backend` (via `Cake.Search.search_chunks_with_context/5`).
  Those are deferred — see #112's description.
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

  describe "config-driven defaults" do
    test "reads embedding model from application config", %{conn: conn} do
      Application.put_env(:cake, :default_provider, :openai)
      Application.put_env(:cake, :default_embedding_model, "text-embedding-3-large")

      Application.put_env(:cake, Cake.Embeddings,
        openai_key: "test-key",
        base_url: "http://localhost/v1/embeddings",
        req_options: [plug: {Req.Test, Cake.Embeddings}]
      )

      on_exit(fn ->
        Application.delete_env(:cake, :default_provider)
        Application.delete_env(:cake, :default_embedding_model)
        Application.delete_env(:cake, Cake.Embeddings)
      end)

      test_pid = self()

      Req.Test.stub(Cake.Embeddings, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:embed_called, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "object" => "list",
            "data" => [%{"embedding" => List.duplicate(0.1, 1536)}],
            "model" => "text-embedding-3-large",
            "usage" => %{"prompt_tokens" => 5, "total_tokens" => 5}
          })
        )
      end)

      {:ok, lv, _} = live(conn, ~p"/search")
      Req.Test.allow(Cake.Embeddings, self(), lv.pid)

      lv
      |> form("form", %{"query" => "hello"})
      |> render_submit()

      assert_receive {:embed_called, body}
      assert body["model"] == "text-embedding-3-large"
    end
  end

  # The search flow needs an embedding service and a search backend (see the
  # moduledoc), so these render the template with results in hand.
  describe "results" do
    defp results_html(results) do
      %{
        __changed__: nil,
        flash: %{},
        current_user: %Cake.Accounts.User{username: "ada.lovelace", role: :member},
        form: Phoenix.Component.to_form(%{"query" => ""}),
        loading: false,
        error: nil,
        results: results
      }
      |> CakeWeb.SearchLive.render()
      |> rendered_to_string()
      |> Floki.parse_fragment!()
    end

    defp book_result do
      %{
        book_title: "Reverse Osmosis Systems",
        source_file_path: "books/ro-systems.pdf",
        total_pages: 412,
        hit_count: 2,
        pages: [
          %{page_number: 12, section_title: "Flow rates", chunk_preview: "400 gallons per day"},
          %{page_number: 97, section_title: nil, chunk_preview: "Replace the pre-filter"}
        ]
      }
    end

    test "shows each book as a card: a title linking to the download, the hit count, a chip per page" do
      html = results_html([book_result()])
      [card] = Floki.find(html, "#search-results article")

      assert [{"a", _attrs, _children} = title] = Floki.find(card, "h2 a")
      assert title |> Floki.text() |> String.trim() == "Reverse Osmosis Systems"
      assert Floki.attribute(title, "href") == ["/books/download/books/ro-systems.pdf"]

      assert Floki.text(card) =~ "2 relevant sections found"
      assert Floki.text(card) =~ "p. 12"
      assert Floki.text(card) =~ "Flow rates"
      assert Floki.text(card) =~ "p. 97"
    end

    test "encodes the storage key in the download link, segment by segment" do
      result = %{book_result() | source_file_path: "reports/Q3 #2 100%.pdf"}
      [title] = [result] |> results_html() |> Floki.find("#search-results h2 a")

      assert Floki.attribute(title, "href") == ["/books/download/reports/Q3%20%232%20100%25.pdf"]
    end

    test "every page chip can be reached with the keyboard and is described by its preview" do
      html = results_html([book_result()])
      chips = Floki.find(html, ~s|#search-results [tabindex="0"]|)

      assert length(chips) == 2

      previews =
        for chip <- chips do
          [preview_id] = Floki.attribute(chip, "aria-describedby")
          [preview] = Floki.find(html, "#" <> preview_id)

          assert Floki.attribute(preview, "role") == ["tooltip"]
          preview |> Floki.text() |> String.trim()
        end

      assert previews == ["400 gallons per day", "Replace the pre-filter"]
    end

    test "gives every preview an id of its own, across books" do
      second = %{book_result() | book_title: "Water Treatment Handbook"}
      html = results_html([book_result(), second])

      ids = html |> Floki.find(~s|#search-results [role="tooltip"]|) |> Floki.attribute("id")

      assert length(ids) == 4
      assert Enum.uniq(ids) == ids
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

      lv
      |> form("form", %{"query" => "hello"})
      |> render_submit()

      html = render_async(lv)

      refute html =~ "Transport layer error"
      assert html =~ "Search failed"
    end
  end
end
