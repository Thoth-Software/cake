defmodule Cake.Books.PdfExtraction do
  @moduledoc """
  Elixir-side struct for the Rust NIF's PdfExtraction.
  Rustler decodes into this automatically via NifStruct.
  """

  @typedoc """
  The NIF's whole-document result: the extracted pages, the PDF metadata title
  if it has one, and the pages it could not extract.
  """
  @type t :: %__MODULE__{
          pages: [Cake.Books.PageContent.t()],
          title: String.t() | nil,
          skipped: [Cake.Books.SkippedPage.t()]
        }

  defstruct [:pages, :title, skipped: []]
end
