defmodule Cake.Embeddings.Behaviour do
  @moduledoc """
  Behaviour for embedding services.

  This behaviour defines the contract for services that generate
  embeddings from parsed documents.
  """

  @typedoc """
  Result of a successful embedding call.

  `struct` is the input struct passed back through unchanged, so the caller can
  pair the embedding with the record it embedded (nil when the caller did not
  supply one). `attrs` carries the embedding for an `update_*` changeset.
  """
  @type embedding_result :: %{
          usage: map(),
          struct: struct() | nil,
          attrs: %{embedding: [float()]}
        }

  @callback embed(atom(), map(), String.t()) ::
              {:ok, embedding_result()} | {:error, String.t()}
end
