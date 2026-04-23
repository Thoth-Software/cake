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
  @spec list_parsed_documents() :: [struct()]
  def list_parsed_documents do
    Repo.all(ParsedDocument)
  end

  @doc """
  Gets a single parsed document.
  Raises `Ecto.NoResultsError` if the document does not exist.
  """
  @spec get_parsed_document!(binary()) :: struct()
  def get_parsed_document!(id), do: Repo.get!(ParsedDocument, id)

  @doc """
  Creates a parsed document.
  """
  @spec create_parsed_document(map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def create_parsed_document(attrs \\ %{}) do
    %ParsedDocument{}
    |> ParsedDocument.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a parsed document.
  """
  @spec update_parsed_document(struct(), map()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def update_parsed_document(%ParsedDocument{} = parsed_document, attrs) do
    parsed_document
    |> ParsedDocument.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a parsed document.
  """
  @spec delete_parsed_document(struct()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def delete_parsed_document(%ParsedDocument{} = parsed_document) do
    Repo.delete(parsed_document)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking parsed document changes.
  """
  @spec change_parsed_document(struct(), map()) :: Ecto.Changeset.t()
  def change_parsed_document(%ParsedDocument{} = parsed_document, attrs \\ %{}) do
    ParsedDocument.changeset(parsed_document, attrs)
  end

  @spec create_parsed_docs!({:ok, [map()]}) :: Enumerable.t()
  def create_parsed_docs!({:ok, parsed_docs_list}) do
    parsed_docs_list
    |> Task.async_stream(&create_parsed_doc!/1, max_concurrency: 10, timeout: 5_000)
    |> Stream.map(fn {:ok, doc} -> doc end)
  end

  @spec create_parsed_doc!(map()) :: struct()
  def create_parsed_doc!(attrs) do
    %ParsedDocument{}
    |> ParsedDocument.changeset(attrs)
    |> Cake.Repo.insert!(log: false, on_replace: :replace_all)
  end

  @spec update_parsed_doc!(struct(), map()) :: struct()
  def update_parsed_doc!(%ParsedDocument{} = parsed_document, attrs) do
    parsed_document
    |> ParsedDocument.changeset(attrs)
    |> Repo.update!(log: false)
  end

  @spec by_language_and_version(String.t(), String.t()) :: [struct()]
  def by_language_and_version(language, version) do
    ParsedDocument.base_query()
    |> ParsedDocument.by_language(language)
    |> ParsedDocument.by_version(version)
    |> Repo.all(log: false)
  end

  @spec by_source_and_version(String.t(), String.t()) :: [struct()]
  def by_source_and_version(source, version) do
    ParsedDocument.base_query()
    |> ParsedDocument.by_source(source)
    |> ParsedDocument.by_version(version)
    |> Repo.all(log: false)
  end

  @doc """
  Hydrates `ParsedDocument` records from a list of OpenSearch hits.

  Used by the `Cake.GDS` `load_from_hits/1` callback on `ParsedDocument`.
  Preserves hit order so downstream ranking is respected.
  """
  @spec load_from_hits([Snap.Hit.t()]) :: [ParsedDocument.t()]
  def load_from_hits(hits) do
    ids = Enum.map(hits, fn hit -> hit.source["id"] end)

    docs_by_id =
      ParsedDocument
      |> where([d], d.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.flat_map(ids, fn id ->
      case Map.get(docs_by_id, id) do
        nil -> []
        doc -> [doc]
      end
    end)
  end
end
