defmodule Cake.HexdocsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Cake.Documents.Hexdocs` context.
  """

  @doc """
  Generate a hexdoc.
  """
  @spec hexdoc_fixture(map()) :: Cake.Documents.Hexdocs.Hexdoc.t()
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
      |> Cake.Documents.Hexdocs.create_hexdoc()

    hexdoc
  end
end
