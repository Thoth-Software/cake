defmodule Cake.GDS do
  @moduledoc """
  Module-level contract implemented by every Generic Data Structure (GDS).

  A GDS answers four questions about its searchable records:

    * Which OpenSearch index holds them?
    * Which fields should full-text search target, and with what boosts?
    * How do I hydrate search hits back into structs?
    * Optionally: how do I expand a set of hits with neighboring records
      (e.g. surrounding chunks in an ordered book)?

  See the README's "Cardinality: How GDSes, Data Structures, and Pipelines
  Relate" section for how a GDS relates to its ingestion pipelines and to
  the data structures that compose it. In particular, a GDS maps 1:1 to a
  pipeline behaviour and 1:many to Ecto schemas.

  ## Why a behaviour rather than a protocol

  The question this contract answers is "which *module* is responsible for
  this GDS?" — how to index it, how to search it, how to rehydrate its hits.
  That is behaviour territory: module-level dispatch against a contract.
  Compare `Cake.Promptable`, which is a protocol because the question it
  answers is "what does *this value* know how to render as prompt context?" —
  value-level dispatch against a struct type.

  ## Declaration pattern

  Schemas opt in with `use Cake.GDS`, which pulls in both the `@behaviour`
  attribute and a trivial identity default for `expand_with_neighbors/2` via
  `defoverridable`. The static callbacks — `index_name/0` and `search_fields/0`
  — live on the schema module directly, because they are compile-time
  constants the schema has full knowledge of. The repo-hitting callbacks —
  `load_from_hits/1` and `expand_with_neighbors/2` — delegate from the schema
  to the corresponding context module (e.g. `Cake.Books`), because that is
  where the Repo-aware query functions live.

  ## Return types

  Retrieval callbacks return `[struct()]` rather than a specific struct type.
  This is deliberate — the retrieval unit of a GDS is not necessarily the
  GDS's identity schema. A `ParsedBook` + `Chunk` GDS declares its retrieval
  unit as `Cake.Books.Chunk.t()`; a `ParsedDocument` GDS declares its
  retrieval unit as `Cake.Documents.ParsedDocument.t()`. Framework code
  consuming these callbacks stays polymorphic over the struct shape and
  leans on `Cake.Promptable` (and the existing `Cake.Citable`) for
  per-struct behavior.

  ## Optional `expand_with_neighbors/2`

  GDSes with no ordering concept — `ParsedDocument` is the canonical example,
  since a documentation entry has no notion of "the record next to it" —
  inherit the identity default supplied by `use Cake.GDS` and do not need to
  override the callback. GDSes with ordering — `ParsedBook` + `Chunk`, where
  chunks are ordered within a book — override it with a real neighbor-fetch
  implementation.

  @todo Phase 2: add worked example linking to Cake.Books.ParsedBook impl.
  """

  @doc """
  Returns the OpenSearch index name that holds the atomic searchable
  records for this GDS (e.g. `"chunks_of_books"`, `"docs"`).
  """
  @callback index_name() :: String.t()

  @doc """
  Returns the list of fields that keyword search should target, in the
  OpenSearch `multi_match` format. Fields may include a caret-boost suffix:
  `"title^2"` means matches on `title` are boosted by a factor of 2 relative
  to unboosted fields.
  """
  @callback search_fields() :: [String.t()]

  @doc """
  Hydrates a list of OpenSearch hits into structs. Implementations typically
  delegate to a context function that extracts the hit IDs and runs a single
  `Repo.all/1` to fetch the full records in one query.
  """
  @callback load_from_hits(hits :: [Snap.Hit.t()]) :: [struct()]

  @doc """
  Expands a list of retrieved records with neighbors on either side, given
  an `offset` window size. Ordered GDSes override this with a real
  neighbor-fetch. Unordered GDSes (e.g. `Cake.Documents.ParsedDocument`)
  inherit the identity default supplied by `use Cake.GDS`, which returns
  `units` unchanged.
  """
  @callback expand_with_neighbors(units :: [struct()], offset :: non_neg_integer()) ::
              [struct()]

  @optional_callbacks expand_with_neighbors: 2

  @doc """
  Declares the calling module as a `Cake.GDS` implementation and supplies
  an identity default for `expand_with_neighbors/2`. Override the default
  when the GDS has an ordering concept worth expanding on.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Cake.GDS

      @impl Cake.GDS
      def expand_with_neighbors(units, _offset), do: units

      defoverridable expand_with_neighbors: 2
    end
  end
end
