defmodule Caque.Embeddings.Behaviour do
  @moduledoc """
  Behaviour for embedding services.

  This behaviour defines the contract for services that generate
  embeddings from parsed documents.
  """

  alias Caque.Documents.ParsedDocument

  @type embedding_result :: %{
          usage: map(),
          parsed_document: ParsedDocument.t(),
          attrs: %{embedding: [float()]}
        }

  @callback embed(atom(), ParsedDocument.t(), String.t()) ::
              {:ok, embedding_result()} | {:error, String.t()}
end
