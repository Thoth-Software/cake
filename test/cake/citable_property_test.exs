defmodule Cake.CitablePropertyTest do
  @moduledoc """
  Conformance properties for every `Cake.Citable` implementation in `lib/`.

  The protocol contract is a map of exactly five keys. Both implementations
  also derive `preview` the same way, as the first 200 graphemes of `text`,
  so that is pinned here once rather than per implementation. Example tests
  live in `citable_test.exs` and `documents/parsed_document_citable_test.exs`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Citable
  alias Cake.Documents.ParsedDocument

  @preview_length 200

  # Unicode text, so the grapheme/byte distinction in the preview is exercised.
  defp text, do: string(:utf8, max_length: 400)

  defp chunk do
    gen all(
          text <- text(),
          page <- one_of([constant(nil), integer(1..500)]),
          section <-
            one_of([constant(nil), string(:alphanumeric, min_length: 1, max_length: 16)]),
          title <- string(:alphanumeric, min_length: 1, max_length: 16)
        ) do
      %Chunk{
        id: Ecto.UUID.generate(),
        text: text,
        page_number: page,
        section_title: section,
        chunk_index: 0,
        parsed_book: %ParsedBook{title: title, source_file_path: "books/#{title}.pdf"}
      }
    end
  end

  defp parsed_document do
    gen all(
          text <- text(),
          package <- string(:alphanumeric, min_length: 1, max_length: 12),
          title <- string(:alphanumeric, min_length: 1, max_length: 12)
        ) do
      %ParsedDocument{
        id: Ecto.UUID.generate(),
        package: package,
        title: title,
        url: "https://hexdocs.pm/elixir/#{package}.html",
        text: text,
        version: "1.0.0",
        language: "elixir",
        source: "hexdocs"
      }
    end
  end

  defp citable, do: one_of([chunk(), parsed_document()])

  property "metadata/1 returns exactly the five contract keys, with the documented types" do
    check all(unit <- citable()) do
      metadata = Citable.metadata(unit)

      assert Enum.sort(Map.keys(metadata)) == [:extras, :id, :label, :preview, :source_ref]
      assert metadata.id == unit.id
      assert is_binary(metadata.label)
      assert is_binary(metadata.preview)
      assert is_binary(metadata.source_ref) or is_nil(metadata.source_ref)
      assert is_map(metadata.extras)
    end
  end

  property "preview is the text's first #{@preview_length} graphemes: a prefix, never longer" do
    check all(unit <- citable()) do
      preview = Citable.metadata(unit).preview

      assert preview == String.slice(unit.text, 0, @preview_length)
      assert String.length(preview) <= @preview_length
      assert String.starts_with?(unit.text, preview)
    end
  end
end
