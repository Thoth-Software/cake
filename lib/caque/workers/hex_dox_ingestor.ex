defmodule Caque.Workers.HexDocsIngestor do
  use Oban.Worker, queue: :ingestion, max_attempts: 3

  @impl Oban.Worker
  def perform(_job) do
    ### Download HexDocs standard library docs
    _ = HexDocsDownloader.download("phoenix") #needs to handle errors

    ### Parse docs into structured JSON or Elixir struct
    #parsed_docs = Caque.HexDocsParser.parse(docs)

    ### Generate embeddings via your Embeddings Context
    #embeddings = Caque.Embeddings.generate(parsed_docs)

    ### Index embeddings into OpenSearch/Elasticsearch via your Search Context
    #:ok = Caque.Search.index_embeddings(embeddings)

    :ok
  end
end
