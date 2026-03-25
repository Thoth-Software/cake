defmodule Cake.Documents.Hexdocs.Hexdoc do
  use Cake.Schema
  import Ecto.Query, warn: false
  import Ecto.Changeset

  @source "hexdocs"
  @language "elixir"

  schema "hexdocs" do
    field :module, :string
    field :version, :string
    field :core, :boolean, default: true
    field :url, :string
    field :content, :string
    field :source, :string, default: @source
    field :language, :string, default: @language

    timestamps(type: :utc_datetime)
  end

  def doc_attrs(), do: %{source: @source, language: @language}

  @doc false
  def changeset(hexdoc, attrs) do
    hexdoc
    |> cast(attrs, [:version, :module, :core, :url, :content])
    |> validate_required([:version, :module, :core, :url, :content])
  end

  def base_query(), do: from(h in __MODULE__)

  def by_version(query, version) do
    from h in query,
      where: h.version == ^version
  end

  def to_parsed_docs({:ok, hexdoc}), do: to_parsed_docs(hexdoc)

  def to_parsed_docs(
        %__MODULE__{content: content, url: url, module: module, version: version} = _hexdoc
      ) do
    case Code.string_to_quoted(content) do
      {:ok, {:defmodule, _, _} = ast} ->
        partial_docs = extract_from_module_ast(ast)

        Enum.map(partial_docs, fn %{text: text, title: title} ->
          %{
            text: text,
            url: url,
            package: module,
            language: @language,
            title: title,
            version: version,
            source: @source
          }
        end)

      {:ok, _other} ->
        # IO.warn("Skipping non-module AST: #{inspect(other)}")
        []

      {:error, _err} ->
        # IO.warn("Could not parse #{content}: #{inspect(err)}")
        []
    end
  end

  defp extract_from_module_ast({:defmodule, _, [_name, [do: {:__block__, _, lines}]]}) do
    extract_docs_and_defs(lines, nil, [])
    |> Enum.reverse()
  end

  defp extract_from_module_ast({:defmodule, _, [_name, [do: single]]}) do
    extract_docs_and_defs([single], nil, [])
    |> Enum.reverse()
  end

  defp extract_from_module_ast({:__block__, _, list}) do
    Enum.flat_map(list, &extract_from_module_ast/1)
  end

  defp extract_docs_and_defs([], _doc, acc), do: acc

  defp extract_docs_and_defs([head | tail], current_doc, acc) do
    case head do
      {:@, _, [{:doc, _, [doc_string]}]} ->
        extract_docs_and_defs(tail, doc_string, acc)

      {def_type, _, _} = fun when def_type in [:def, :defp] ->
        name = extract_name(fun)
        arity = extract_arity(fun)
        code = Macro.to_string(fun)
        docstring = extract_doc(current_doc)

        item = %{
          text: "#{docstring}\n\n#{code}",
          title: "#{name}/#{arity}"
        }

        extract_docs_and_defs(tail, nil, [item | acc])

      _ ->
        # We're not interested in non-doc/function AST nodes
        extract_docs_and_defs(tail, current_doc, acc)
    end
  end

  defp extract_name({_, _, [{{:unquote, _, [name]}, _, _} | _]}), do: name
  defp extract_name({_, _, [{name, _, _} | _]}), do: name
  defp extract_arity({_, _, [_head, body]}), do: length(body)
  defp extract_arity({_, _, [_]}), do: 0

  defp extract_doc(doc) when is_binary(doc), do: doc
  defp extract_doc([doc]), do: extract_doc(doc)

  defp extract_doc(doc) when is_list(doc) do
    Enum.map_join(doc, fn {atom, string} ->
      "#{atom}: #{string}\n"
    end) <> "\n"
  end

  defp extract_doc(_), do: nil
end
