defmodule Cake.Documents do
  @moduledoc """
  Ingestion context for programming documentation (the `ParsedDocument` GDS).

  This module is the `Boundary` anchor for the `Cake.Documents.*` namespace;
  the pipeline behaviour and its implementations live beneath it.
  """

  use Boundary,
    top_level?: true,
    deps: [Cake, Cake.Search, Cake.Embeddings, Cake.Pipelines],
    exports: [Pipeline, Hexdocs.Pipeline, ParsedDocument]
end
