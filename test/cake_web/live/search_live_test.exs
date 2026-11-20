defmodule CakeWeb.SearchLiveTest do
  @moduledoc """
  Tests for `CakeWeb.SearchLive`: mounting, the states the screen can be
  in, and how results are shown.

  Most render the template with assigns in hand. A search through the
  LiveView itself needs the embedding service and the search backend stood
  in for (`Req.Test` for `Cake.Embeddings`, `Cake.Search.Backend.Mock` for
  the backend); "a search that finds nothing" does that, and its setup is
  the one to reuse. A search that returns hits also needs the hits' records
  in the database, which no test here sets up yet (#112).
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

  # A search that returns hits needs their records in the database (see the
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
        last_query: nil,
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

  # The three states a search can be in besides showing results (#392). Each
  # is one of the shared state components, under the id the screen had.
  describe "states" do
    defp state_html(assigns) do
      %{
        __changed__: nil,
        flash: %{},
        current_user: %Cake.Accounts.User{username: "ada.lovelace", role: :member},
        form: Phoenix.Component.to_form(%{"query" => ""}),
        loading: false,
        error: nil,
        last_query: nil,
        results: []
      }
      |> Map.merge(assigns)
      |> CakeWeb.SearchLive.render()
      |> rendered_to_string()
      |> Floki.parse_fragment!()
    end

    defp state_text(html, selector) do
      html
      |> Floki.find(selector)
      |> Floki.text()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
    end

    test "before any search there is no result, no empty state, no indicator and no error" do
      html = state_html(%{})

      for id <- ~w(search-results search-empty search-loading search-error) do
        assert Floki.find(html, "#" <> id) == []
      end
    end

    test "while searching, a status says so" do
      html = state_html(%{loading: true})

      assert [indicator] = Floki.find(html, "#search-loading")
      assert Floki.attribute(indicator, "role") == ["status"]
      assert state_text(html, "#search-loading") == "Searching..."
    end

    test "a failed search shows its message as an error notice" do
      html = state_html(%{error: "Search failed. Please try again."})

      assert [notice] = Floki.find(html, "#search-error")
      assert Floki.attribute(notice, "role") == ["alert"]
      assert state_text(html, "#search-error") == "Search failed. Please try again."
    end

    test "a search that found nothing says so, naming the query" do
      html = state_html(%{last_query: "reverse osmosis"})

      assert state_text(html, "#search-empty") =~ "reverse osmosis"
      assert Floki.find(html, "#search-results") == []
    end

    test "the empty state gives way to the indicator while the next search runs" do
      html = state_html(%{last_query: "reverse osmosis", loading: true})

      assert Floki.find(html, "#search-empty") == []
      assert [_indicator] = Floki.find(html, "#search-loading")
    end

    test "the empty state gives way to the error when the next search fails" do
      html =
        state_html(%{last_query: "reverse osmosis", error: "Search failed. Please try again."})

      assert Floki.find(html, "#search-empty") == []
      assert [_notice] = Floki.find(html, "#search-error")
    end

    test "results are shown without the empty state" do
      html = state_html(%{last_query: "reverse osmosis", results: [book_result()]})

      assert Floki.find(html, "#search-empty") == []
      assert [_results] = Floki.find(html, "#search-results")
    end
  end

  # One search through the LiveView itself, with the embedding service and
  # the search backend stood in for, so the state above is reached by a real
  # search and not only by rendering the template.
  describe "a search that finds nothing" do
    setup do
      previous =
        for key <- [:search_backend, :default_provider, :default_embedding_model, Cake.Embeddings] do
          {key, Application.fetch_env(:cake, key)}
        end

      Application.put_env(:cake, :search_backend, Cake.Search.Backend.Mock)
      Application.put_env(:cake, :default_provider, :openai)
      Application.put_env(:cake, :default_embedding_model, "text-embedding-ada-002")

      Application.put_env(:cake, Cake.Embeddings,
        openai_key: "test-key",
        base_url: "http://localhost/v1/embeddings",
        req_options: [plug: {Req.Test, Cake.Embeddings}]
      )

      on_exit(fn ->
        for {key, value} <- previous do
          case value do
            {:ok, value} -> Application.put_env(:cake, key, value)
            :error -> Application.delete_env(:cake, key)
          end
        end
      end)
    end

    test "shows the empty state, naming the query, and no results", %{conn: conn} do
      test_pid = self()

      Req.Test.stub(Cake.Embeddings, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:embedded, Jason.decode!(body)["input"]})

        Req.Test.json(conn, %{
          "object" => "list",
          "data" => [%{"embedding" => List.duplicate(0.1, 1536)}],
          "model" => "text-embedding-ada-002",
          "usage" => %{"prompt_tokens" => 2, "total_tokens" => 2}
        })
      end)

      Mox.stub(Cake.Search.Backend.Mock, :search, fn %Cake.Search.Query{} -> {:ok, []} end)

      {:ok, lv, _} = live(conn, ~p"/search")
      Req.Test.allow(Cake.Embeddings, self(), lv.pid)
      Mox.allow(Cake.Search.Backend.Mock, self(), lv.pid)

      refute has_element?(lv, "#search-empty")

      lv
      |> form("#search-form", %{"query" => "  reverse osmosis  "})
      |> render_submit()

      render_async(lv)

      # The query is trimmed once: what is searched for is what is named.
      assert_received {:embedded, "reverse osmosis"}
      assert lv |> element("#search-empty") |> render() =~ "“reverse osmosis”"
      refute has_element?(lv, "#search-results")
      refute has_element?(lv, "#search-loading")
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
