defmodule Cake.Support.FixtureGDS do
  @moduledoc """
  In-memory `Cake.GDS` implementation for testing.

  Used to prove `Cake.Search.OpenSearch` dispatches through the `:gds` module
  argument rather than hardcoding `Cake.Books.ParsedBook`. Also serves as
  living documentation for future GDS authors: the minimum surface area
  needed to satisfy the behaviour.

  Records callback invocations via `Process.put/2` so tests can assert which
  callbacks were routed through the fixture without needing to inspect
  OpenSearch-side traffic.
  """

  use Cake.GDS

  defmodule Record do
    @moduledoc false
    defstruct [:id, :body]

    @type t :: %__MODULE__{id: term(), body: String.t()}
  end

  @calls_key {__MODULE__, :calls}

  @spec calls() :: [atom()]
  def calls, do: Process.get(@calls_key, [])

  @spec reset_calls() :: :ok
  def reset_calls do
    Process.put(@calls_key, [])
    :ok
  end

  @impl Cake.GDS
  def index_name do
    record_call(:index_name)
    "fixture_index"
  end

  @impl Cake.GDS
  def search_fields do
    record_call(:search_fields)
    ["body"]
  end

  @impl Cake.GDS
  def load_from_hits(hits) do
    record_call(:load_from_hits)

    Enum.map(hits, fn hit ->
      id = extract_id(hit)
      body = extract_body(hit, id)
      %Record{id: id, body: body}
    end)
  end

  defp extract_id(%{source: %{"id" => id}}), do: id
  defp extract_id(%{"_id" => id}), do: id
  defp extract_id(%{id: id}), do: id
  defp extract_id(id) when is_binary(id), do: id

  defp extract_body(%{source: %{"body" => body}}, _id), do: body
  defp extract_body(%{"_source" => %{"body" => body}}, _id), do: body
  defp extract_body(_hit, id), do: "fixture-body-#{id}"

  defp record_call(name) do
    Process.put(@calls_key, [name | Process.get(@calls_key, [])])
  end
end
