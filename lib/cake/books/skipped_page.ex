defmodule Cake.Books.SkippedPage do
  @moduledoc """
  Elixir-side struct for pages the Rust NIF could not extract text from.
  Rustler decodes into this automatically via NifStruct.
  """

  defstruct [:page_number, :reason]
end
