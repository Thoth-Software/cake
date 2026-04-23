defmodule Cake.Documents.ParsedDocumentCitableTest do
  use ExUnit.Case, async: true

  alias Cake.Citable
  alias Cake.Documents.ParsedDocument

  describe "Cake.Citable implementation" do
    test "returns a map with exactly the five required keys" do
      doc = %ParsedDocument{
        id: Ecto.UUID.generate(),
        package: "Enum",
        title: "map/2",
        url: "https://hexdocs.pm/elixir/Enum.html#map/2",
        text: "some text",
        version: "1.15.0",
        language: "elixir",
        source: "hexdocs"
      }

      keys = doc |> Citable.metadata() |> Map.keys() |> Enum.sort()
      assert keys == [:extras, :id, :label, :preview, :source_ref]
    end

    test "returns metadata map with id, label, source_ref, preview, extras" do
      id = Ecto.UUID.generate()

      doc = %ParsedDocument{
        id: id,
        package: "Enum",
        title: "map/2",
        url: "https://hexdocs.pm/elixir/Enum.html#map/2",
        text: String.duplicate("a", 500),
        version: "1.15.0",
        language: "elixir",
        source: "hexdocs"
      }

      metadata = Citable.metadata(doc)

      assert metadata.id == id
      assert metadata.label == "Enum — map/2"
      assert metadata.source_ref == "https://hexdocs.pm/elixir/Enum.html#map/2"
      assert metadata.preview == String.duplicate("a", 200)

      assert metadata.extras == %{
               package: "Enum",
               title: "map/2",
               version: "1.15.0",
               language: "elixir",
               source: "hexdocs"
             }
    end

    test "preview returns full text when text is shorter than 200 chars" do
      doc = %ParsedDocument{
        id: Ecto.UUID.generate(),
        package: "Enum",
        title: "map/2",
        url: "https://hexdocs.pm/elixir/Enum.html#map/2",
        text: "short text",
        version: "1.15.0",
        language: "elixir",
        source: "hexdocs"
      }

      assert Citable.metadata(doc).preview == "short text"
    end
  end
end
