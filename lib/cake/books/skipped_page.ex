defmodule Cake.Books.SkippedPage do
  @moduledoc """
  Elixir-side struct for the Rust NIF's SkippedPage.
  Rustler decodes into this automatically via NifStruct.
  """

  @typedoc "A page the NIF could not extract, with the reason."
  @type t :: %__MODULE__{
          page_number: non_neg_integer(),
          reason: String.t()
        }

  defstruct [:page_number, :reason]
end
