defmodule Cake.Documents.ParsedDocumentPromptableTest do
  use ExUnit.Case, async: true

  alias Cake.Documents.ParsedDocument
  alias Cake.Promptable

  describe "Cake.Promptable implementation" do
    test "returns template with package, title, url, and text" do
      doc = %ParsedDocument{
        package: "Enum",
        title: "map/2",
        url: "https://hexdocs.pm/elixir/Enum.html#map/2",
        text: "Returns a list where each element is the result of invoking fun..."
      }

      assert Promptable.prompt_context(doc) ==
               "Package: Enum | Function: map/2\n" <>
                 "URL: https://hexdocs.pm/elixir/Enum.html#map/2\n\n" <>
                 "Returns a list where each element is the result of invoking fun..."
    end

    test "applies the same template regardless of :core flag" do
      doc = %ParsedDocument{
        package: "jason",
        title: "encode/2",
        url: "https://hexdocs.pm/jason/Jason.html#encode/2",
        text: "Generates JSON corresponding to input.",
        core: false,
        language: "elixir"
      }

      assert Promptable.prompt_context(doc) ==
               "Package: jason | Function: encode/2\n" <>
                 "URL: https://hexdocs.pm/jason/Jason.html#encode/2\n\n" <>
                 "Generates JSON corresponding to input."
    end

    test "preserves the template shape when :text is empty" do
      doc = %ParsedDocument{
        package: "Enum",
        title: "map/2",
        url: "https://hexdocs.pm/elixir/Enum.html#map/2",
        text: ""
      }

      assert Promptable.prompt_context(doc) ==
               "Package: Enum | Function: map/2\n" <>
                 "URL: https://hexdocs.pm/elixir/Enum.html#map/2\n\n"
    end

    test "returns a String" do
      doc = %ParsedDocument{
        package: "Enum",
        title: "map/2",
        url: "https://hexdocs.pm/elixir/Enum.html#map/2",
        text: "some text"
      }

      assert is_binary(Promptable.prompt_context(doc))
    end
  end
end
