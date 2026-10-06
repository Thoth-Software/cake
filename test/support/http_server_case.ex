defmodule Cake.HttpServerCase do
  @moduledoc """
  Case template for tests that speak to `CakeWeb.Endpoint` over real HTTP
  (#252).

  Every other web test drives the endpoint in-process through
  `Phoenix.ConnTest` and `Phoenix.LiveViewTest`, and `config/test.exs`
  sets `server: false`, so no request ever crosses the HTTP adapter.
  `use Cake.HttpServerCase` tags the module's tests `:integration` and, for
  the module's duration, boots the endpoint with `server: true` on an
  ephemeral loopback port: the same `Bandit.PhoenixAdapter` production
  serves through, its HTTP/1 parser, cookie and header handling and its
  WebSocket upgrade, all on the request path. That makes the suite the
  proof-it-still-serves check for a Bandit upgrade (#206).

  ## How the server is booted

  The endpoint already runs under `Cake.Supervisor`, started from the
  test-env config. `start_server!/0`, from the template's `setup_all`,
  layers `server: true` and `http: [ip: {127, 0, 0, 1}, port: 0]` over
  that config, restarts the endpoint child, and reads the port the OS
  assigned back from `c:Phoenix.Endpoint.server_info/1`, so two runs on
  one machine never collide over a fixed port. Once the module's tests are
  done, `restore_server!/1` puts the original config back and restarts the
  endpoint again, so later modules see it exactly as `config/test.exs`
  left it.

  ## Why `async: false` is mandatory

  Restarting the endpoint is global to the VM: a module on another
  template using the endpoint in-process while this one restarts it would
  see it disappear. ExUnit runs every `async: true` module before the
  first synchronous one and runs synchronous modules one at a time, so an
  `async: false` module restarts the endpoint with nothing else running.
  `use Cake.HttpServerCase, async: true` therefore raises at compile time.
  It also means the Ecto sandbox runs in shared mode, which is what lets
  the Bandit handler and LiveView processes, which the test never spawns
  and so cannot `allow`, reach the test's connection.

  ## Speaking to the server

    * `http/1` is a `Req` request on the server's base URL, with redirects
      and retries off so a test sees each response as the server sent it.
    * `session_cookie/1` picks the session cookie out of a response's
      `set-cookie` headers, as a value for the next request's `cookie`
      header; `csrf_token!/1` reads a page's `csrf-token` meta tag.
    * `live_join!/4` mounts a LiveView the way the browser does: it fetches
      the page over HTTP, upgrades `/live/websocket` (the session cookie,
      the CSRF token, an `Origin` the endpoint's `check_origin` accepts)
      with `Mint.WebSocket`, sends the `phx_join` and returns the reply.
      `rendered_text/1` flattens the reply's rendered tree for `=~`.
  """

  use ExUnit.CaseTemplate

  alias CakeWeb.Endpoint

  @session_cookie "_cake_key"
  @loopback {127, 0, 0, 1}
  @serializer_vsn "2.0.0"
  @join_ref "1"
  @recv_timeout_ms 5_000

  using opts do
    if Keyword.get(opts, :async, false) do
      raise ArgumentError,
            "Cake.HttpServerCase tests cannot be async: the template restarts " <>
              "CakeWeb.Endpoint, which is global to the VM. Drop the async: true."
    end

    quote do
      @moduletag :integration

      import Cake.HttpServerCase
    end
  end

  setup_all do
    original = Application.fetch_env!(:cake, Endpoint)
    on_exit(fn -> restore_server!(original) end)

    %{base_url: start_server!()}
  end

  setup tags do
    Cake.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Boots the endpoint with `server: true` on an ephemeral loopback port and
  returns its base URL (`http://127.0.0.1:<port>`). Restarts the endpoint
  under `Cake.Supervisor`; `restore_server!/1` undoes it.
  """
  @spec start_server!() :: String.t()
  def start_server! do
    config = Application.fetch_env!(:cake, Endpoint)

    Application.put_env(
      :cake,
      Endpoint,
      Keyword.merge(config, server: true, http: [ip: @loopback, port: 0])
    )

    restart_endpoint!()

    {:ok, {ip, port}} = Endpoint.server_info(:http)
    "http://#{:inet.ntoa(ip)}:#{port}"
  end

  @doc """
  Puts the endpoint's `original` config back and restarts it, so it runs
  again as `config/test.exs` configured it (`server: false`).
  """
  @spec restore_server!(keyword()) :: :ok
  def restore_server!(original) when is_list(original) do
    Application.put_env(:cake, Endpoint, original)
    restart_endpoint!()
  end

  @doc """
  A `Req` request against the running server. Redirects and retries are
  off, so every response is the one the server sent.
  """
  @spec http(map()) :: Req.Request.t()
  def http(%{base_url: base_url}) when is_binary(base_url) do
    Req.new(base_url: base_url, redirect: false, retry: false)
  end

  @doc "The name of the endpoint's session cookie (`CakeWeb.Endpoint`'s `@session_options`)."
  @spec session_cookie_name() :: String.t()
  def session_cookie_name, do: @session_cookie

  @doc """
  The session cookie `response` set, as `"name=value"` for the next
  request's `cookie` header; `nil` when the response set none.
  """
  @spec session_cookie(Req.Response.t()) :: String.t() | nil
  def session_cookie(%Req.Response{} = response) do
    response
    |> Req.Response.get_header("set-cookie")
    |> Enum.map(fn header -> header |> String.split(";", parts: 2) |> hd() end)
    |> Enum.find(&String.starts_with?(&1, @session_cookie <> "="))
  end

  @doc "The CSRF token in a page's `csrf-token` meta tag. Raises when there is none."
  @spec csrf_token!(String.t()) :: String.t()
  def csrf_token!(html) when is_binary(html) do
    case html
         |> Floki.parse_document!()
         |> Floki.attribute(~s(meta[name="csrf-token"]), "content") do
      [token | _rest] -> token
      [] -> raise "no csrf-token meta tag in the page"
    end
  end

  @doc """
  Mounts the LiveView at `path` over a real WebSocket, as the browser does:
  fetches the page over HTTP with `cookie`, upgrades `/live/websocket` with
  the same cookie and the page's CSRF token, sends the `phx_join` for the
  page's main LiveView and returns the join reply — `{:ok, rendered}` when
  the LiveView mounted, `{:error, response}` when the join was refused
  (a mount redirect among them). The socket is closed before returning.

  Options:

    * `:csrf_token` — the token to connect and join with instead of the
      page's own.
  """
  @spec live_join!(map(), String.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, map()}
  def live_join!(%{base_url: base_url} = ctx, path, cookie, opts \\ [])
      when is_binary(path) and is_list(opts) do
    page = Req.get!(http(ctx), url: path, headers: cookie_header(cookie))

    unless page.status == 200 do
      raise "GET #{path} answered #{page.status}, not the LiveView page"
    end

    # Rendering the page stores its CSRF state in the session, so the page
    # response usually rotates the cookie; the browser connects with the
    # rotated one, and the old one carries no state the token can match.
    cookie = session_cookie(page) || cookie
    live = main_live_view!(page.body)
    csrf_token = Keyword.get_lazy(opts, :csrf_token, fn -> csrf_token!(page.body) end)

    join = %{
      "url" => base_url <> path,
      "params" => %{"_csrf_token" => csrf_token, "_mounts" => 0},
      "session" => live.session,
      "static" => live.static
    }

    socket = connect_live_socket!(base_url, cookie, csrf_token)

    try do
      topic = "lv:" <> live.id
      socket = send_frame!(socket, [@join_ref, @join_ref, topic, "phx_join", join])
      {_socket, reply} = await_reply!(socket, topic)
      join_result(reply)
    after
      Mint.HTTP.close(socket.conn)
    end
  end

  @doc """
  Every string in a LiveView rendered tree — statics and dynamics, nested
  components and comprehensions included — joined, so a test can `=~` the
  text a mount rendered.
  """
  @spec rendered_text(map()) :: String.t()
  def rendered_text(rendered) when is_map(rendered) do
    rendered |> collect_strings() |> Enum.join()
  end

  defp collect_strings(value) when is_binary(value), do: [value]

  defp collect_strings(value) when is_map(value),
    do: Enum.flat_map(Map.values(value), &collect_strings/1)

  defp collect_strings(value) when is_list(value), do: Enum.flat_map(value, &collect_strings/1)
  defp collect_strings(_value), do: []

  defp restart_endpoint! do
    :ok = Supervisor.terminate_child(Cake.Supervisor, Endpoint)
    {:ok, _pid} = Supervisor.restart_child(Cake.Supervisor, Endpoint)
    :ok
  end

  defp cookie_header(nil), do: []
  defp cookie_header(cookie) when is_binary(cookie), do: [cookie: cookie]

  defp main_live_view!(html) do
    case html |> Floki.parse_document!() |> Floki.find("[data-phx-main]") do
      [element | _rest] ->
        %{
          id: attribute!(element, "id"),
          session: attribute!(element, "data-phx-session"),
          static: attribute!(element, "data-phx-static")
        }

      [] ->
        raise "no main LiveView (data-phx-main) in the page"
    end
  end

  defp attribute!(element, name) do
    case Floki.attribute(element, name) do
      [value | _rest] -> value
      [] -> raise "the main LiveView element has no #{name} attribute"
    end
  end

  # The browser connects with `?_csrf_token=...&vsn=2.0.0` and an Origin
  # header; the socket hands the cookie session to the LiveView only when
  # that token matches the session's, and `check_origin` compares the
  # Origin's host against the endpoint's `url` host.
  defp connect_live_socket!(base_url, cookie, csrf_token) do
    %URI{host: host, port: port} = URI.parse(base_url)
    origin = "http://#{Endpoint.config(:url)[:host]}:#{port}"
    query = URI.encode_query(%{"_csrf_token" => csrf_token, "vsn" => @serializer_vsn})

    headers = [
      {"origin", origin} | Enum.map(cookie_header(cookie), fn {_k, v} -> {"cookie", v} end)
    ]

    {:ok, conn} = Mint.HTTP.connect(:http, host, port, protocols: [:http1], mode: :passive)
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/live/websocket?" <> query, headers)
    {conn, status, response_headers} = await_upgrade!(conn, ref, %{})

    case Mint.WebSocket.new(conn, ref, status, response_headers, mode: :passive) do
      {:ok, conn, websocket} ->
        %{conn: conn, ref: ref, websocket: websocket, frames: []}

      {:error, _conn, reason} ->
        raise "WebSocket upgrade of /live/websocket refused (HTTP #{status}): #{inspect(reason)}"
    end
  end

  defp await_upgrade!(conn, ref, acc) do
    {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, @recv_timeout_ms)

    acc =
      Enum.reduce(responses, acc, fn
        {:status, ^ref, status}, acc -> Map.put(acc, :status, status)
        {:headers, ^ref, headers}, acc -> Map.put(acc, :headers, headers)
        {:done, ^ref}, acc -> Map.put(acc, :done, true)
        _other, acc -> acc
      end)

    case acc do
      %{status: status, headers: headers, done: true} -> {conn, status, headers}
      _incomplete -> await_upgrade!(conn, ref, acc)
    end
  end

  defp send_frame!(socket, message) do
    {:ok, websocket, data} =
      Mint.WebSocket.encode(socket.websocket, {:text, Jason.encode!(message)})

    {:ok, conn} = Mint.WebSocket.stream_request_body(socket.conn, socket.ref, data)
    %{socket | conn: conn, websocket: websocket}
  end

  # Reads frames until the reply to our join arrives; other pushes on the
  # socket (none are expected before the join reply) are skipped.
  defp await_reply!(%{frames: [frame | rest]} = socket, topic) do
    socket = %{socket | frames: rest}

    case frame do
      {:text, text} ->
        case Jason.decode!(text) do
          [@join_ref, @join_ref, ^topic, "phx_reply", payload] -> {socket, payload}
          _other -> await_reply!(socket, topic)
        end

      {:close, code, reason} ->
        raise "the server closed the LiveView socket (#{code}): #{inspect(reason)}"

      _control ->
        await_reply!(socket, topic)
    end
  end

  defp await_reply!(%{frames: []} = socket, topic) do
    case Mint.WebSocket.recv(socket.conn, 0, @recv_timeout_ms) do
      {:ok, conn, responses} ->
        data = for {:data, ref, data} <- responses, ref == socket.ref, into: "", do: data
        {:ok, websocket, frames} = Mint.WebSocket.decode(socket.websocket, data)
        await_reply!(%{socket | conn: conn, websocket: websocket, frames: frames}, topic)

      {:error, _conn, reason, _responses} ->
        raise "no join reply on the LiveView socket: #{inspect(reason)}"
    end
  end

  defp join_result(%{"status" => "ok", "response" => %{"rendered" => rendered}}),
    do: {:ok, rendered}

  defp join_result(%{"status" => "error", "response" => response}), do: {:error, response}

  defp join_result(payload) do
    raise "unexpected join reply: #{inspect(payload)}"
  end
end
