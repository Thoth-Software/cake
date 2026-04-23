defmodule Cake.Test.StubChunk do
  @moduledoc """
  Test-only stub struct that implements `Cake.Citable` by returning the
  metadata map it was constructed with. Lets Responses tests exercise the
  pipeline without coupling to `Cake.Books.Chunk` or the database.
  """

  @type t :: %__MODULE__{metadata: Cake.Citable.metadata()}
  defstruct [:metadata]
end

defimpl Cake.Citable, for: Cake.Test.StubChunk do
  @spec metadata(Cake.Test.StubChunk.t()) :: Cake.Citable.metadata()
  def metadata(%{metadata: m}), do: m
end
