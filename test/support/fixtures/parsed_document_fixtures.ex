defmodule Caque.ParsedDocumentFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Caque.Documents.ParsedDocuments` context.
  """

  @doc """
  Generate a parsed_documents.
  """
  def parsed_documents_fixture(attrs \\ %{}) do
    {:ok, parsed_documents} =
      attrs
      |> Enum.into(%{
        text: "some text",
        core: true,
        title: "some title",
        package: "some package",
        url: "some url",
        version: "some version",
        source: "some source"
      })
      |> Caque.Documents.ParsedDocuments.create_parsed_document()

    parsed_documents
  end
end
