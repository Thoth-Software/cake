defmodule Cake.Books.PdfExtraction do
  @moduledoc """
  Elixir-side struct for the Rust NIF's PdfExtraction.
  Rustler decodes into this automatically via NifStruct.
  """

  defstruct [:pages, skipped: []]
end
