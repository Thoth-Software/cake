defmodule Cake.HttpServerCase do
  @moduledoc """
  Case template for tests that speak to `CakeWeb.Endpoint` over real HTTP
  (#252).

  Stub: the real template is the next commit on #252. Every helper raises,
  so a suite on it fails red for the missing seam, not a compile error.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      import Cake.HttpServerCase
    end
  end

  setup_all do
    %{base_url: start_server!()}
  end

  @doc "Boots the endpoint with `server: true` on an ephemeral port; returns its base URL."
  @spec start_server!() :: String.t()
  def start_server!, do: not_implemented!()

  @doc "A `Req` request against the running server."
  @spec http(map()) :: Req.Request.t()
  def http(%{base_url: _base_url}), do: not_implemented!()

  @doc "The name of the endpoint's session cookie."
  @spec session_cookie_name() :: String.t()
  def session_cookie_name, do: not_implemented!()

  @doc "The session cookie a response set, as a `cookie` request header value."
  @spec session_cookie(Req.Response.t()) :: String.t() | nil
  def session_cookie(%Req.Response{}), do: not_implemented!()

  @doc "The CSRF token in a page's `csrf-token` meta tag."
  @spec csrf_token!(String.t()) :: String.t()
  def csrf_token!(html) when is_binary(html), do: not_implemented!()

  @doc "Mounts the LiveView at `path` over a real WebSocket and returns the join reply."
  @spec live_join!(map(), String.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, map()}
  def live_join!(%{base_url: _base_url}, path, _cookie, opts \\ [])
      when is_binary(path) and is_list(opts),
      do: not_implemented!()

  @doc "Every static string in a LiveView rendered tree, joined."
  @spec rendered_text(map()) :: String.t()
  def rendered_text(rendered) when is_map(rendered), do: not_implemented!()

  defp not_implemented! do
    raise "Cake.HttpServerCase is a stub: the real-HTTP server boot is not implemented yet (#252)"
  end
end
