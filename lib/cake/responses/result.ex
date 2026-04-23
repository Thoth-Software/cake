defmodule Cake.Responses.Result do
  @moduledoc """
  The structured value returned by `Cake.Responses.process/3`.

  Each field has a clear owner in the pipeline:

    * `raw_text` — populated on construction; never modified.
    * `final_text` — the display text after renumbering and formatting.
      In Step 2, this mirrors `raw_text`. Step 3 populates it properly.
    * `chunk_map` — integer index → `Cake.Citable.metadata()`. Built from
      `indexed_chunks` at the top of the pipeline.
    * `citations` — ordered, deduplicated citation records with both
      old_index (what the LLM wrote) and new_index (what the user sees).
      In Step 2, new_index == old_index (no renumbering yet).
    * `media` — image items selected for display. Empty in Step 2.
    * `actions` — download buttons, external links, etc. Empty in Step 2.
    * `assigns` — passthrough map for tenant-specific or view-specific
      data that doesn't fit the typed fields.
    * `warnings` — non-fatal issues, structured as `{atom, term}` tuples
      for pattern-matchability.
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

  @type media_item :: %{
          required(:kind) => :image,
          required(:url) => String.t(),
          required(:alt) => String.t(),
          required(:citation_index) => pos_integer()
        }

  @type action :: %{
          required(:kind) => :download | :external_link,
          required(:label) => String.t(),
          required(:source_ref) => String.t()
        }

  @type warning :: {:hallucinated_citation, pos_integer()} | {atom(), term()}

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
