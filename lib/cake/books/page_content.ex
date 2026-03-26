defmodule Cake.Books.PageContent do
  @moduledoc """
  Elixir-side struct for the Rust NIF's PageContent.
  Rustler decodes into this automatically via NifStruct.
  """

  defstruct [:page_number, :text]
end
