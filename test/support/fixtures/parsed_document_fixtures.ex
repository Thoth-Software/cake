defmodule Caque.ParsedDocumentFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Caque.ParsedDocument` context.
  """

  @doc """
  Generate a parsed_documents.
  """
  def parsed_documents_fixture(attrs \\ %{}) do
    {:ok, parsed_documents} =
      attrs
      |> Enum.into(%{
        contenet: "some contenet",
        core: true,
        function: "some function",
        module: "some module",
        url: "some url",
        version: "some version"
      })
      |> Caque.ParsedDocument.create_parsed_documents()

    parsed_documents
  end
end
