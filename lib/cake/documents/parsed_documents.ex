defmodule Cake.Documents.ParsedDocuments do
  @moduledoc """
  The ParsedDocuments context.
  """

  import Ecto.Query, warn: false

  alias Cake.Documents.ParsedDocument
  alias Cake.Repo

  @doc """
  Returns the list of parsed documents.
  """
  def list_parsed_documents do
    Repo.all(ParsedDocument)
  end

  @doc """
  Gets a single parsed document.
  Raises `Ecto.NoResultsError` if the document does not exist.
  """
  def get_parsed_document!(id), do: Repo.get!(ParsedDocument, id)

  @doc """
  Creates a parsed document.
  """
  def create_parsed_document(attrs \\ %{}) do
    %ParsedDocument{}
    |> ParsedDocument.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a parsed document.
  """
  def update_parsed_document(%ParsedDocument{} = parsed_document, attrs) do
    parsed_document
    |> ParsedDocument.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a parsed document.
  """
  def delete_parsed_document(%ParsedDocument{} = parsed_document) do
    Repo.delete(parsed_document)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking parsed document changes.
  """
  def change_parsed_document(%ParsedDocument{} = parsed_document, attrs \\ %{}) do
    ParsedDocument.changeset(parsed_document, attrs)
  end

  def create_parsed_docs!({:ok, parsed_docs_list}) do
    Task.async_stream(
      parsed_docs_list,
      max_concurrency: 10,
      timeout: 5_000
    )
    |> Stream.map(&create_parsed_doc!/1)
  end

  def create_parsed_doc!(attrs) do
    %ParsedDocument{}
    |> ParsedDocument.changeset(attrs)
    |> Cake.Repo.insert!(log: false, on_replace: :replace_all)
  end

  def update_parsed_doc!(%ParsedDocument{} = parsed_document, attrs) do
    parsed_document
    |> ParsedDocument.changeset(attrs)
    |> Repo.update!(log: false)
  end

  def by_language_and_version(language, version) do
    ParsedDocument.base_query()
    |> ParsedDocument.by_language(language)
    |> ParsedDocument.by_version(version)
    |> Repo.all(log: false)
  end

  def by_source_and_version(source, version) do
    ParsedDocument.base_query()
    |> ParsedDocument.by_source(source)
    |> ParsedDocument.by_version(version)
    |> Repo.all(log: false)
  end
end
