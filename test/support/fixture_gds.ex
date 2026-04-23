defmodule Cake.Support.FixtureGDS do
  @moduledoc """
  In-memory `Cake.GDS` implementation for testing.

  Does double duty:

    1. **Fast test fixture.** Implements the full `Cake.GDS` contract without
       needing OpenSearch, the Repo, or any real schema. Tests that exercise
       GDS-agnostic orchestration code (`Cake.Search.OpenSearch`,
       `Cake.Conversation`, `Cake.Prompt` via `Cake.Promptable`) can thread
       `gds: Cake.Support.FixtureGDS` through the `:gds` opt and run in
       isolation.

    2. **Living documentation.** Shows the minimum surface area a new GDS
       author must cover: one `use Cake.GDS`, three required callbacks
       (`index_name/0`, `search_fields/0`, `load_from_hits/1`), and — if the
       GDS has ordering — an override for `expand_with_neighbors/2`.
       FixtureGDS inherits the identity default, the same way
       `Cake.Documents.ParsedDocument` does.

  ## Callback walkthrough

    * `index_name/0` — the OpenSearch index this GDS owns. A real GDS returns
      a string like `"chunks_of_books"` or `"docs"`. FixtureGDS returns
      `"fixture_index"` — a name that doesn't exist in any real cluster so
      accidental production traffic fails loudly.

    * `search_fields/0` — the fields keyword search targets, with optional
      caret-boost suffixes (`"title^3"`). FixtureGDS targets a single field
      `"body"` so its `Record` struct stays trivially small.

    * `load_from_hits/1` — hydrates hits into structs. A real GDS's
      implementation runs one Repo query, preserving hit order. FixtureGDS
      synthesizes `%Record{}` values directly from hit payloads — no Repo
      involvement — and tolerates multiple hit shapes (`%Snap.Hit{}`,
      OpenSearch-raw `"_id"`/`"_source"` maps, bare ID binaries) so tests
      can pick whichever shape reads best at the call site.

    * `expand_with_neighbors/2` — inherited from `use Cake.GDS`, which
      supplies an identity default. A FixtureGDS record has no ordering
      concept, so the default is correct — mirroring `ParsedDocument`.

  ## Call recording

  FixtureGDS records every callback invocation via `Process.put/2`. Tests
  can call `calls/0` to read the list and `reset_calls/0` to clear it.
  This lets dispatch tests assert *which* GDS callbacks orchestration code
  routed through without mocking OpenSearch-side traffic.

  ## Typical usage

      setup do
        Cake.Support.FixtureGDS.reset_calls()
        :ok
      end

      test "some search flow routes through the GDS" do
        # ...invoke code that accepts `gds: Cake.Support.FixtureGDS`...
        assert :index_name in Cake.Support.FixtureGDS.calls()
      end

  When building a real GDS, use FixtureGDS as a structural reference: mirror
  the `use Cake.GDS` declaration and the shape of each `@impl Cake.GDS`
  callback. Drop the Process-dict call recording — production GDSes have no
  use for it.
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
