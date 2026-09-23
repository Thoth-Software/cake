defmodule Cake.Search.HTTPClientStub do
  @moduledoc """
  `Snap.HTTPClient` adapter for the test env.

  `config/test.exs` installs it on `Cake.Search.Deployment`, so every Snap
  request the OpenSearch backend makes under test reaches `request/6`
  instead of the network. A test that wants to drive
  `Cake.Search.Backend.OpenSearch` through Snap's real request and
  response-parsing path calls `put_responder/1` with a function that
  returns the HTTP response; the function is stored in the calling
  process's dictionary, so concurrent tests never see each other's
  responders. A process with no responder gets a transport error, which
  is what an unreachable cluster would produce.
  """

  @behaviour Snap.HTTPClient

  alias Snap.HTTPClient.Error
  alias Snap.HTTPClient.Response

  @type responder ::
          (Snap.HTTPClient.method(),
           Snap.HTTPClient.url(),
           Snap.HTTPClient.headers(),
           Snap.HTTPClient.body() ->
             {:ok, Response.t()} | {:error, Error.t()})

  @doc "Serves this process's Snap requests from `fun` until the process exits."
  @spec put_responder(responder()) :: :ok
  def put_responder(fun) when is_function(fun, 4) do
    Process.put(__MODULE__, fun)
    :ok
  end

  @doc "Builds a JSON HTTP response with the given status and decoded body."
  @spec json_response(non_neg_integer(), map()) :: {:ok, Response.t()}
  def json_response(status, body) when is_integer(status) and is_map(body) do
    {:ok,
     %Response{
       status: status,
       body: Jason.encode!(body),
       headers: [{"content-type", "application/json"}]
     }}
  end

  @impl Snap.HTTPClient
  @spec child_spec(keyword()) :: :skip
  def child_spec(_config), do: :skip

  @impl Snap.HTTPClient
  @spec request(
          module(),
          Snap.HTTPClient.method(),
          Snap.HTTPClient.url(),
          Snap.HTTPClient.headers(),
          Snap.HTTPClient.body(),
          keyword()
        ) :: {:ok, Response.t()} | {:error, Error.t()}
  def request(_cluster, method, url, headers, body, _opts) do
    case Process.get(__MODULE__) do
      fun when is_function(fun, 4) -> fun.(method, url, headers, body)
      nil -> {:error, Error.new(:no_responder, __MODULE__)}
    end
  end
end
