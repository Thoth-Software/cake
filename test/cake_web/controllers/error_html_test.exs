defmodule CakeWeb.ErrorHTMLTest do
  @moduledoc """
  The error pages (#375): every status gets the same page, with its code,
  its standard message and a link home, and a request that fails gets that
  page inside the root layout, so it is styled.
  """

  use CakeWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template

  defp error_page(status) do
    CakeWeb.ErrorHTML
    |> render_to_string(Integer.to_string(status), "html", [])
    |> Floki.parse_fragment!()
  end

  defp text(html, selector), do: html |> Floki.find(selector) |> Floki.text() |> String.trim()

  test "renders 404.html: the code, \"Not Found\" and a link home" do
    html = error_page(404)

    assert text(html, "#error-status") == "404"
    assert text(html, "#error-message") == "Not Found"
    assert Floki.attribute(html, "#error-home", "href") == ["/"]
  end

  test "renders 500.html: the code, \"Internal Server Error\" and a link home" do
    html = error_page(500)

    assert text(html, "#error-status") == "500"
    assert text(html, "#error-message") == "Internal Server Error"
    assert Floki.attribute(html, "#error-home", "href") == ["/"]
  end

  test "renders every other status the same way, with its own code and message" do
    for status <- [400, 401, 403, 405, 408, 413, 422, 429, 502, 503] do
      html = error_page(status)

      assert text(html, "#error-status") == Integer.to_string(status)
      assert text(html, "#error-message") == Plug.Conn.Status.reason_phrase(status)
      assert Floki.attribute(html, "#error-home", "href") == ["/"]
    end
  end

  describe "a request for a page that does not exist" do
    test "is answered 404 with the error page inside the root layout", %{conn: conn} do
      html = conn |> get("/no/such/page") |> html_response(404) |> Floki.parse_document!()

      assert text(html, "#error-status") == "404"
      assert text(html, "#error-message") == "Not Found"

      # The root layout is what brings the stylesheet and the title.
      assert Floki.find(html, ~s|link[rel="stylesheet"][href^="/assets/css/app"]|) != []
      assert text(html, "title") == "Cake"
    end

    test "carries no Phoenix branding", %{conn: conn} do
      body = conn |> get("/no/such/page") |> html_response(404)

      refute body =~ "Phoenix Framework"
      refute body =~ "phoenixframework.org"
    end

    test "is still answered in JSON, with no layout, when JSON is asked for", %{conn: conn} do
      conn = conn |> put_req_header("accept", "application/json") |> get("/no/such/page")

      assert json_response(conn, 404) == %{"errors" => %{"detail" => "Not Found"}}
    end
  end
end
