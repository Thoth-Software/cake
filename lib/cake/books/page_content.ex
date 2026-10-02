defmodule Cake.Books.PageContent do
  @moduledoc """
  Elixir-side struct for the Rust NIF's PageContent.
  Rustler decodes into this automatically via NifStruct.
  """

  @typedoc "One extracted page: its page number and text."
  @type t :: %__MODULE__{
          page_number: non_neg_integer(),
          text: String.t()
        }

  defstruct [:page_number, :text]
end
