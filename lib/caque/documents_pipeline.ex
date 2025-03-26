defmodule Caque.Documents.Pipeline do
  @moduledoc """
  Behaviour for document ingestion pipelines.

  Modules implementing this pipeline live under the Caque.Documents namespace, with Caque.Documents.NameOfSource being the same of each source module. Modules are abstractions over data types; in this case, the data type is "documents from a particular source".

  RATIONALE: Document ingestion is implemented via Oban jobs. The modules instigating document ingestino must be agnostic as to the particulars of each document source. Therefore, we use a behaviour to abstract away those details and expose callbacks for ingestion, parsing into JSON, conversion to embeddings, and storage. Breaking these tasks apart and exposing each one as a public function allows for greater observability and easier debugging.

  The pipeline runs download -> save_raw -> parse -> save_parsed -> embed -> save_embeddings.
  Download: fetch docs from source
  Parse: Parse to JSON
  Embed: convert to embeddings

  We save raw docs, parsed JSON,and embeddings in separate tables, which is why we call "save" at each point in the pipeline.

  If, at any point, we want to stop saving raw docs or JSON, we can rewrite the save function to allow bypass.
  """

  @type version :: {integer(), integer(), integer()}

  @callback download(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  @callback save_raw([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  @callback parse(any()) :: {:ok, String.t()} | {:error, any()}
  @callback embed(any()) :: {:ok, any()} | {:error, any()}

  # @spec ingest(atom(), version()) :: {:ok, any()} | {:error, any()}
  # def ingest(module) do
  #   version = Enum.join([major, minor, patch], ".")
  # end
end
