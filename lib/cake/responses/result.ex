defmodule Cake.Responses.Result do
  @moduledoc """
  The structured value returned by `c:Cake.Responses.Behaviour.process/3`.

  Each field has a clear owner in the pipeline:

    * `raw_text` — populated on construction; never modified.
    * `final_text` — the display text after citation renumbering, marker
      rewriting, and whitespace cleanup.
    * `chunk_map` — integer index → `Cake.Citable.metadata()`. Built from
      `indexed_chunks` at the top of the pipeline.
    * `citations` — ordered, deduplicated citation records with both
      old_index (what the LLM wrote) and new_index (what the user sees).
    * `media` — image items selected for display. `select_media` is
      currently a stub, so this is always empty today.
    * `actions` — download buttons, external links, etc. Currently one
      `:download` action per unique citation `source_ref`.
    * `assigns` — passthrough map for tenant-specific or view-specific
      data that doesn't fit the typed fields.
    * `warnings` — non-fatal issues, structured as `{atom, term}` tuples
      for pattern-matchability.
  """

  @typedoc """
  One surviving citation: the index the model wrote (`old_index`), the
  renumbered index the user sees (`new_index`), and the `Cake.Citable` metadata
  it resolves to.
  """
  @type citation :: %{
          old_index: pos_integer(),
          new_index: pos_integer(),
          id: term(),
          label: String.t(),
          preview: String.t(),
          source_ref: String.t() | nil,
          extras: map()
        }

  @typedoc """
  An image selected for display beside the citation it belongs to. Media
  selection is a stub, so none are produced today.
  """
  @type media_item :: %{
          required(:kind) => :image,
          required(:url) => String.t(),
          required(:alt) => String.t(),
          required(:citation_index) => pos_integer()
        }

  @typedoc "A UI action derived from the citations, such as a download of a cited `source_ref`."
  @type action :: %{
          required(:kind) => :download | :external_link,
          required(:label) => String.t(),
          required(:source_ref) => String.t()
        }

  @typedoc """
  A non-fatal issue: `{:hallucinated_citation, n}` for an `[n]` marker that
  resolved to no chunk, or another `{atom, term}`.
  """
  @type warning :: {:hallucinated_citation, pos_integer()} | {atom(), term()}

  @typedoc "The structured response; the moduledoc gives each field's owner."
  @type t :: %__MODULE__{
          raw_text: String.t(),
          final_text: String.t() | nil,
          chunk_map: map(),
          citations: [citation()],
          media: [media_item()],
          actions: [action()],
          assigns: map(),
          warnings: [warning()]
        }

  defstruct raw_text: nil,
            final_text: nil,
            chunk_map: %{},
            citations: [],
            media: [],
            actions: [],
            assigns: %{},
            warnings: []
end
