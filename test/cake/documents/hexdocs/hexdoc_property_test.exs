defmodule Cake.Documents.Hexdocs.HexdocPropertyTest do
  @moduledoc """
  Property tests for the Hexdocs context and the `Hexdoc` schema.

  `hexdoc_exists?/2` recognizes the (module, version) natural key of any
  persisted hexdoc. `Hexdoc.to_parsed_docs/1` is compared against the model
  `Cake.HexdocGenerators` builds alongside each generated module: one entry
  per `def`/`defp` clause and none for any other form, titles from the head,
  the `@doc` carried on the clause that follows it, `doc_attrs/0` plus the
  row's identity on every entry, and totality over arbitrary text. Example
  tests live in `hexdocs_test.exs` and `hexdoc_test.exs`.
  """

  use Cake.DataCase, async: true
  use ExUnitProperties

  import Cake.HexdocsFixtures

  alias Cake.Documents.Hexdocs
  alias Cake.Documents.Hexdocs.Hexdoc
  alias Cake.HexdocGenerators

  describe "hexdoc_exists?/2" do
    property "is true for the (module, version) of any persisted hexdoc" do
      check all(
              module <- string(:alphanumeric, min_length: 1),
              version <- string(:alphanumeric, min_length: 1)
            ) do
        hexdoc_fixture(%{module: module, version: version})
        assert Hexdocs.hexdoc_exists?(module, version)
      end
    end
  end

  describe "to_parsed_docs/1" do
    defp hexdoc(content) do
      %Hexdoc{
        content: content,
        url: "https://hexdocs.pm/elixir/Example.html",
        module: "Example",
        version: "1.0.0"
      }
    end

    defp parse(spec), do: spec |> HexdocGenerators.render() |> hexdoc() |> Hexdoc.to_parsed_docs()

    property "emits one entry per def/defp clause, in source order, titled name/arity from the head" do
      check all(spec <- HexdocGenerators.module_spec()) do
        expected_titles = spec |> HexdocGenerators.expected_entries() |> Enum.map(&elem(&1, 0))

        assert Enum.map(parse(spec), & &1.title) == expected_titles
      end
    end

    property "skips every non-function form (macros, guards, delegates, attributes, alias, require)" do
      check all(spec <- HexdocGenerators.module_spec()) do
        definitions = Enum.filter(spec, &(&1.item == :definition))
        clause_count = definitions |> Enum.map(& &1.clauses) |> Enum.sum()

        docs = parse(spec)

        assert length(docs) == clause_count

        refute Enum.any?(
                 docs,
                 &(&1.text =~ ~r/\b(defmacro|defguard|defdelegate|alias|require)\b/)
               )
      end
    end

    property "a string @doc is carried on the clause that follows it, and only there" do
      check all(spec <- HexdocGenerators.module_spec()) do
        pairs = Enum.zip(HexdocGenerators.expected_entries(spec), parse(spec))

        for {{_title, doc}, entry} <- pairs do
          case doc do
            {:string, text} -> assert String.starts_with?(entry.text, text)
            # No @doc, @doc false, and the later clauses of a documented
            # definition all render an empty doc ahead of the code.
            doc when doc in [nil, false] -> assert String.starts_with?(entry.text, "\n\n")
            # Sigil and keyword docs are pinned by the property below.
            {other, _} when other in [:sigil, :keyword] -> :ok
          end
        end
      end
    end

    property "every entry's text ends in the clause's own code" do
      check all(spec <- HexdocGenerators.module_spec()) do
        definitions = Enum.filter(spec, &(&1.item == :definition))

        clause_heads =
          Enum.flat_map(definitions, &List.duplicate("#{&1.kind} #{&1.name}", &1.clauses))

        for {head, entry} <- Enum.zip(clause_heads, parse(spec)) do
          assert entry.text =~ "\n\n#{head}"
        end
      end
    end

    property "every entry carries doc_attrs/0 and the row's url, package and version, and nothing else" do
      check all(
              spec <- HexdocGenerators.module_spec(),
              url <- string(:alphanumeric, min_length: 1),
              module <- string(:alphanumeric, min_length: 1),
              version <- string(:alphanumeric, min_length: 1)
            ) do
        row = %Hexdoc{
          content: HexdocGenerators.render(spec),
          url: url,
          module: module,
          version: version
        }

        %{source: source, language: language} = Hexdoc.doc_attrs()

        for entry <- Hexdoc.to_parsed_docs(row) do
          assert Enum.sort(Map.keys(entry)) ==
                   [:language, :package, :source, :text, :title, :url, :version]

          assert %{
                   source: ^source,
                   language: ^language,
                   url: ^url,
                   package: ^module,
                   version: ^version
                 } =
                   entry
        end
      end
    end

    property "accepts the row bare or as {:ok, row} with the same result" do
      check all(spec <- HexdocGenerators.module_spec()) do
        row = spec |> HexdocGenerators.render() |> hexdoc()
        assert Hexdoc.to_parsed_docs({:ok, row}) == Hexdoc.to_parsed_docs(row)
      end
    end

    property "is total: any printable content yields a list, never a raise" do
      check all(content <- string(:printable)) do
        assert content |> hexdoc() |> Hexdoc.to_parsed_docs() |> is_list()
      end
    end
  end
end
