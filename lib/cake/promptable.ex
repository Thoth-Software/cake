defprotocol Cake.Promptable do
  @moduledoc """
  Value-level contract implemented by any struct that can be rendered as
  LLM prompt context. `prompt_context/1` returns the text block that will
  be injected into the prompt as retrieved context for this value —
  typically as one entry in the numbered list of retrieved chunks that
  `Cake.Prompt` assembles before handing the messages list to
  `Cake.Generation`.

  ## Distinction from `Cake.Citable`

  `Cake.Promptable` and `Cake.Citable` will almost always be implemented
  side-by-side on the same struct, and their boundaries blur without
  vigilance. The distinction is the audience:

    * `Cake.Citable` produces **display metadata for the end user** — a
      map with `:label`, `:source_ref`, `:preview`, `:extras`, etc., used
      by the frontend to render citations attached to an answer.
    * `Cake.Promptable` produces **prompt text for the LLM** — a plain
      string injected into the prompt body as context for generation.

  The same struct typically implements both, but the outputs are
  different strings serving different audiences. For a
  `Cake.Books.Chunk`, the Citable impl returns something like
  `%{label: "Book Title — Page 12", source_ref: "book:42#chunk:5", ...}`
  for the UI; the Promptable impl returns the chunk's `text` wrapped with
  section title and page number, formatted for LLM consumption.

  Keep them firmly separated. If a field makes sense only to the model,
  it belongs in the Promptable output. If it makes sense only to the end
  user's citation display, it belongs in the Citable output. If a change
  to one starts demanding changes to the other, treat that as a smell
  rather than a reason to merge them.

  ## Why a protocol rather than a behaviour

  The question this contract answers is "what does *this value* know how
  to render as prompt context?" That is protocol territory: value-level
  dispatch keyed on the struct's type. Compare `Cake.GDS`, which is a
  behaviour because the question it answers is "which *module* is
  responsible for this GDS?" — module-level dispatch against a contract.

  ## How this chains with `Cake.GDS`

  A GDS's `load_from_hits/1` callback returns a list of structs. Those
  structs implement `Cake.Promptable`. Orchestration code (e.g.
  `Cake.Prompt.format_chunk/1` and its siblings) can then call
  `Cake.Promptable.prompt_context/1` polymorphically without knowing the
  struct type — the behaviour handles module-level "which GDS?" dispatch,
  the protocol handles value-level "how does this struct render?"
  dispatch, and the seam between retrieval and prompt assembly stays
  GDS-agnostic.
  """

  @doc """
  Returns the text block that will be injected into the LLM prompt as
  retrieved context for this value.
  """
  @spec prompt_context(t()) :: String.t()
  def prompt_context(value)
end
