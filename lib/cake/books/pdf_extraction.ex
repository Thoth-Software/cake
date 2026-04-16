defmodule Cake.Books.PdfExtraction do
  @moduledoc """
  Elixir-side struct for the Rust NIF's PdfExtraction.
  Rustler decodes into this automatically via NifStruct.
  """

  @type t :: %__MODULE__{
          pages: [Cake.Books.PageContent.t()],
          title: String.t() | nil,
          skipped: [Cake.Books.SkippedPage.t()]
        }

  defstruct [:pages, :title, skipped: []]
end
