defmodule Cake.Embeddings.Behaviour do
  @moduledoc """
  Behaviour for embedding services.

  This behaviour defines the contract for services that generate
  embeddings from parsed documents.
  """

  @type embedding_result :: %{
          usage: map(),
          parsed_document: struct(),
          attrs: %{embedding: [float()]}
        }

  @callback embed(atom(), struct(), String.t()) ::
              {:ok, embedding_result()} | {:error, String.t()}
end
