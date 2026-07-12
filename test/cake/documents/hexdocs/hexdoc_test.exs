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

    test "sanitizes NUL bytes in string fields" do
      cs =
        Hexdoc.changeset(%Hexdoc{}, %{
          version: "1.0",
          module: "Foo\0Bar",
          core: true,
          url: "https://example.com",
          content: "some content"
        })

      assert Ecto.Changeset.get_change(cs, :module) == "FooBar"
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
    test "extracts function docs and code from a simple module" do
      content = """
      defmodule Example do
        @doc "Adds two numbers."
        def add(a, b), do: a + b

        @doc "Subtracts b from a."
        def subtract(a, b), do: a - b
      end
      """

      hexdoc = %Hexdoc{
        content: content,
        url: "https://hexdocs.pm/elixir/Example.html",
        module: "Example",
        version: "1.0.0"
      }

      docs = Hexdoc.to_parsed_docs(hexdoc)

      assert length(docs) == 2

      add_doc = Enum.find(docs, &(&1.text =~ "Adds two numbers."))
      assert add_doc
      assert add_doc.text =~ "def add(a, b)"
      assert add_doc.url == "https://hexdocs.pm/elixir/Example.html"
      assert add_doc.package == "Example"
      assert add_doc.language == "elixir"
      assert add_doc.version == "1.0.0"
      assert add_doc.source == "hexdocs"
    end

    test "handles functions without @doc" do
      content = """
      defmodule Example do
        def helper(x), do: x
      end
      """

      hexdoc = %Hexdoc{
        content: content,
        url: "https://hexdocs.pm/elixir/Example.html",
        module: "Example",
        version: "1.0.0"
      }

      docs = Hexdoc.to_parsed_docs(hexdoc)

      assert length(docs) == 1
      assert hd(docs).title == "helper/1"
    end

    test "handles zero-arity functions" do
      content = """
      defmodule Example do
        def greeting, do: "hello"
      end
      """

      hexdoc = %Hexdoc{
        content: content,
        url: "https://hexdocs.pm/elixir/Example.html",
        module: "Example",
        version: "1.0.0"
      }

      docs = Hexdoc.to_parsed_docs(hexdoc)

      assert [doc] = docs
      assert doc.title =~ "greeting/"
    end

    test "ignores private functions" do
      content = """
      defmodule Example do
        def public_fn(x), do: x
        defp private_fn(x), do: x
      end
      """

      hexdoc = %Hexdoc{
        content: content,
        url: "https://hexdocs.pm/elixir/Example.html",
        module: "Example",
        version: "1.0.0"
      }

      docs = Hexdoc.to_parsed_docs(hexdoc)
      titles = Enum.map(docs, & &1.title)

      assert "public_fn/1" in titles
      assert "private_fn/1" in titles
    end

    test "returns empty list for non-module AST" do
      hexdoc = %Hexdoc{
        content: "1 + 2",
        url: "https://hexdocs.pm/elixir/Example.html",
        module: "Example",
        version: "1.0.0"
      }

      assert Hexdoc.to_parsed_docs(hexdoc) == []
    end

    test "returns empty list for unparseable content" do
      hexdoc = %Hexdoc{
        content: "defmodule Broken do {{{{",
        url: "https://hexdocs.pm/elixir/Broken.html",
        module: "Broken",
        version: "1.0.0"
      }

      assert Hexdoc.to_parsed_docs(hexdoc) == []
    end

    test "accepts {:ok, hexdoc} tuple" do
      hexdoc = %Hexdoc{
        content: "defmodule X do\n  def f, do: :ok\nend",
        url: "https://hexdocs.pm/elixir/X.html",
        module: "X",
        version: "1.0.0"
      }

      docs = Hexdoc.to_parsed_docs({:ok, hexdoc})
      assert length(docs) == 1
    end

    test "handles @doc with keyword list format" do
      content = """
      defmodule Example do
        @doc [since: "1.0", deprecated: "Use other/0"]
        def old_fn, do: :ok
      end
      """

      hexdoc = %Hexdoc{
        content: content,
        url: "https://hexdocs.pm/elixir/Example.html",
        module: "Example",
        version: "1.0.0"
      }

      docs = Hexdoc.to_parsed_docs(hexdoc)
      assert length(docs) == 1
      assert hd(docs).text =~ "since"
    end

    test "module with no functions returns empty list" do
      content = """
      defmodule Empty do
        @moduledoc "Nothing here"
      end
      """

      hexdoc = %Hexdoc{
        content: content,
        url: "https://hexdocs.pm/elixir/Empty.html",
        module: "Empty",
        version: "1.0.0"
      }

      assert Hexdoc.to_parsed_docs(hexdoc) == []
    end
  end
end
