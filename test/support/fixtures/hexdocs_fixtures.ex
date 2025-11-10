defmodule Caque.HexdocsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Caque.Documents.Hexdocs` context.
  """

  @doc """
  Generate a hexdoc.
  """
  def hexdoc_fixture(attrs \\ %{}) do
    {:ok, hexdoc} =
      attrs
      |> Enum.into(%{
        content: "some content",
        core: true,
        module: "some module",
        url: "some url",
        version: "some version"
      })
      |> Caque.Documents.Hexdocs.create_hexdoc()

    hexdoc
  end
end
