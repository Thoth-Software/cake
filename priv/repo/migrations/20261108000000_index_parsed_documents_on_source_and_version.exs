defmodule Cake.Repo.Migrations.IndexParsedDocumentsOnSourceAndVersion do
  use Ecto.Migration

  # A corpus is the parsed documents sharing a source and version. The retry
  # paths' model check (#284) reads a whole corpus per retried document, and
  # the ingest dedup (`ParsedDocuments.parsed_doc_exists?/4`) looks up
  # source + version + package + title per parsed document; without an
  # index both scan every corpus in the table. The leading (source, version)
  # columns serve both.
  def change do
    create index(:parsed_documents, [:source, :version])
  end
end
