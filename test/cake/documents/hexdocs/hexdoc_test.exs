defmodule Cake.Documents.Hexdocs.HexdocTest do
  use Cake.DataCase, async: true

  import Cake.HexdocsFixtures

  alias Cake.Documents.Hexdocs.Hexdoc

  describe "doc_attrs/0" do
    test "returns source and language" do
      attrs = Hexdoc.doc_attrs()
      assert attrs.source == "hexdocs"
      assert attrs.language == "elixir"
    end
  end

  describe "changeset/2" do
    test "valid with all required fields" do
      cs =
        Hexdoc.changeset(%Hexdoc{}, %{
          version: "1.18.3",
          module: "Enum",
          core: true,
          url: "https://hexdocs.pm/elixir/Enum.html",
          content: "defmodule Enum do end"
        })

      assert cs.valid?
    end

    test "invalid when required fields are missing" do
      cs = Hexdoc.changeset(%Hexdoc{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert errors[:version]
      assert errors[:module]
      assert errors[:url]
      assert errors[:content]
    end
  end

  describe "base_query/0 and by_version/2" do
    test "by_version/2 filters hexdocs by version" do
      hexdoc_fixture(%{version: "1.18.3", module: "Enum"})
      hexdoc_fixture(%{version: "1.17.0", module: "Map"})

      results = Hexdoc.base_query() |> Hexdoc.by_version("1.18.3") |> Repo.all()

      assert length(results) == 1
      assert hd(results).version == "1.18.3"
    end
  end

  describe "by_module/2" do
    test "filters hexdocs by module" do
      hexdoc_fixture(%{version: "1.18.3", module: "Enum"})
      hexdoc_fixture(%{version: "1.18.3", module: "Map"})

      results = Hexdoc.base_query() |> Hexdoc.by_module("Enum") |> Repo.all()

      assert length(results) == 1
      assert hd(results).module == "Enum"
    end

    test "composes with by_version/2 to select on the (module, version) natural key" do
      hexdoc_fixture(%{version: "1.18.3", module: "Enum"})
      hexdoc_fixture(%{version: "1.17.0", module: "Enum"})
      hexdoc_fixture(%{version: "1.18.3", module: "Map"})

      results =
        Hexdoc.base_query()
        |> Hexdoc.by_module("Enum")
        |> Hexdoc.by_version("1.18.3")
        |> Repo.all()

      assert length(results) == 1
      assert hd(results).module == "Enum"
      assert hd(results).version == "1.18.3"
    end
  end

  describe "to_parsed_docs/1" do
    # The contract is pinned by the properties in `hexdoc_property_test.exs`
    # (one entry per def/defp clause, titles from the head, docs carried on
    # the clause that follows them, skipped forms, attrs, totality). These
    # examples are the readable anchors and the edge cases outside the
    # generator's reach.
    defp hexdoc(content) do
      %Hexdoc{
        content: content,
        url: "https://hexdocs.pm/elixir/Example.html",
        module: "Example",
        version: "1.0.0"
      }
    end

    test "extracts function docs and code from a simple module" do
      content = """
      defmodule Example do
        @doc "Adds two numbers."
        def add(a, b), do: a + b

        @doc "Subtracts b from a."
        def subtract(a, b), do: a - b
      end
      """

      docs = Hexdoc.to_parsed_docs(hexdoc(content))

      assert length(docs) == 2

      add_doc = Enum.find(docs, &(&1.text =~ "Adds two numbers."))
      assert add_doc.title == "add/2"
      assert add_doc.text =~ "def add(a, b)"
      assert add_doc.url == "https://hexdocs.pm/elixir/Example.html"
      assert add_doc.package == "Example"
      assert add_doc.language == "elixir"
      assert add_doc.version == "1.0.0"
      assert add_doc.source == "hexdocs"
    end

    test "includes private functions: a defp is retrieval context like a def" do
      content = """
      defmodule Example do
        def public_fn(x), do: x
        defp private_fn(x), do: x
      end
      """

      titles = content |> hexdoc() |> Hexdoc.to_parsed_docs() |> Enum.map(& &1.title)

      assert titles == ["public_fn/1", "private_fn/1"]
    end

    test "handles a sigil @doc (found by the property test)" do
      content = """
      defmodule Example do
        @doc ~S(Raw sigil doc with a \\ backslash.)
        def raw, do: :ok

        @doc ~s(Lowercase sigil doc.)
        def lower, do: :ok
      end
      """

      docs = Hexdoc.to_parsed_docs(hexdoc(content))

      assert Enum.map(docs, &String.split(&1.text, "\n\n", parts: 2)) == [
               ["Raw sigil doc with a \\ backslash.", "def raw do\n  :ok\nend"],
               ["Lowercase sigil doc.", "def lower do\n  :ok\nend"]
             ]
    end

    test "handles a single-key keyword @doc (found by the property test)" do
      content = """
      defmodule Example do
        @doc since: "1.0"
        def new_fn, do: :ok
      end
      """

      assert [%{text: text}] = Hexdoc.to_parsed_docs(hexdoc(content))
      assert text =~ "since: 1.0"
    end

    test "renders a non-string keyword @doc value with inspect/1 instead of raising (review finding)" do
      content = """
      defmodule Example do
        @doc group: [:collections, :enumerables]
        def grouped, do: :ok

        @doc guard: true
        def guarded, do: :ok
      end
      """

      assert [%{text: grouped}, %{text: guarded}] = Hexdoc.to_parsed_docs(hexdoc(content))
      assert grouped =~ "group: [:collections, :enumerables]"
      assert guarded =~ "guard: true"
    end

    test "module with no functions returns empty list" do
      content = """
      defmodule Empty do
        @moduledoc "Nothing here"
      end
      """

      assert Hexdoc.to_parsed_docs(hexdoc(content)) == []
    end

    test "returns empty list for non-module AST" do
      assert Hexdoc.to_parsed_docs(hexdoc("1 + 2")) == []
    end

    test "returns empty list for unparseable content" do
      assert Hexdoc.to_parsed_docs(hexdoc("defmodule Broken do {{{{")) == []
    end
  end
end
