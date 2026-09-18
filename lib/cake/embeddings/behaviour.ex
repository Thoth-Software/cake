defmodule Cake.Embeddings.Behaviour do
  @moduledoc """
  Behaviour for embedding services.

  This behaviour defines the contract for services that generate
  embeddings — for records at ingestion time and for user questions at
  query time alike.
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

  @doc """
  Embeds `params.input` with the given provider atom and model, returning
  the embedding result (token usage, optional struct passthrough, and the
  embedding vector in `attrs`).
  """
  @callback embed(atom(), map(), String.t()) ::
              {:ok, embedding_result()} | {:error, String.t()}
end
