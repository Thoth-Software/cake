defmodule Caque.Documents.ParsedDocuments do
  @moduledoc """
  The ParsedDocuments context.
  """

  import Ecto.Query, warn: false
  alias Caque.Repo
  alias Caque.Documents.ParsedDocument

  def create_parsed_docs!({:ok, parsed_docs_list}) do
    Task.async_stream(
      parsed_docs_list,
      max_concurrency: 10,
      timeout: 5_000
    )
    |> Enum.each(&create_parsed_doc!/1)
  end

  def create_parsed_doc!(%ParsedDocument{} = parsed_document) do
    parsed_document
    |> ParsedDocument.changeset()
    |> Caque.Repo.insert!(log: false)
  end

  def update_parsed_doc(%ParsedDocument{} = parsed_document, attrs) do
    parsed_document
    |> ParsedDocument.changeset(attrs)
    |> Repo.update()
  end

  def by_language_and_version(language, version) do
    ParsedDocument.base_query()
    |> ParsedDocument.by_language(language)
    |> ParsedDocument.by_version(version)
    |> Repo.all()
  end

  def by_source_and_version(source, version) do
    ParsedDocument.base_query()
    |> ParsedDocument.by_source(source)
    |> ParsedDocument.by_version(version)
    |> Repo.all()
  end
end
