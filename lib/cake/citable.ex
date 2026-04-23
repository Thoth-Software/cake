defprotocol Cake.Citable do
  @moduledoc """
  Contract implemented by any atomic unit that can appear as a citation in an
  LLM response. `Cake.Responses` calls `metadata/1` per chunk to build a
  chunk_map without coupling to any specific GDS.

  ## The contract

  `metadata/1` returns a map with exactly five keys:

    * `:id` — stable unique identifier for the unit, used by Responses for
      deduplication when the LLM cites the same unit under two different
      indices. Any pattern-matchable term; UUIDs, tuples, and binaries are
      all fine.
    * `:label` — human-readable display string. The implementation composes
      this from whatever fields make sense for the unit; callers may use
      it verbatim or override via `:extras`.
    * `:preview` — short text excerpt (typically first ~200 chars) for
      tooltips, hover cards, or inline summaries.
    * `:source_ref` — path, URL, or opaque key identifying the source artifact
      for download/link actions. `nil` if the unit has no downloadable source.
    * `:extras` — map of type-specific metadata. Tenant frontends that know
      a particular GDS's shape can reach in; generic frontends can ignore it.

  The protocol is deliberately narrow. Anything beyond the five required keys
  lives in `:extras`, which keeps the contract stable as new GDS types arrive.

  ## Preload requirement

  Implementations may require that Ecto associations needed to compose the
  metadata be preloaded before `metadata/1` is called. It is the caller's
  responsibility to preload. Implementations should let missing associations
  crash rather than returning degraded output.
  """

  @type metadata :: %{
          required(:id) => term(),
          required(:label) => String.t(),
          required(:preview) => String.t(),
          required(:source_ref) => String.t() | nil,
          required(:extras) => map()
        }

  @spec metadata(t) :: metadata()
  def metadata(citable)
end
