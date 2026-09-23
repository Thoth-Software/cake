defmodule Cake.Documents.Hexdocs.Hexdoc do
  @moduledoc """
  Ecto schema for a raw hexdocs row (module, version, url, content) as fetched
  from the `hexdocs` source, before it is parsed into a `ParsedDocument`.
  """

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

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          module: String.t(),
          version: String.t(),
          core: boolean(),
          url: String.t(),
          content: String.t(),
          source: String.t(),
          language: String.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  The source and language identifiers every parsed hexdoc carries. This is
  the single source of truth for those two attrs: `to_parsed_docs/1` merges
  it into each `ParsedDocument` attrs map it emits.
  """
  @spec doc_attrs() :: %{source: String.t(), language: String.t()}
  def doc_attrs(), do: %{source: @source, language: @language}

  @doc false
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(hexdoc, attrs) do
    hexdoc
    |> cast(attrs, [:version, :module, :core, :url, :content])
    |> validate_required([:version, :module, :core, :url, :content])
    |> sanitize_text_fields()
  end

  @spec base_query() :: Ecto.Query.t()
  def base_query(), do: from(h in __MODULE__)

  @spec by_version(Ecto.Query.t(), String.t()) :: Ecto.Query.t()
  def by_version(query, version) do
    from h in query,
      where: h.version == ^version
  end

  @spec by_module(Ecto.Query.t(), String.t()) :: Ecto.Query.t()
  def by_module(query, module) do
    from h in query,
      where: h.module == ^module
  end

  @spec to_parsed_docs({:ok, %__MODULE__{}} | %__MODULE__{}) :: [map()]
  def to_parsed_docs({:ok, hexdoc}), do: to_parsed_docs(hexdoc)

  def to_parsed_docs(
        %__MODULE__{content: content, url: url, module: module, version: version} = _hexdoc
      ) do
    case Code.string_to_quoted(content) do
      {:ok, {:defmodule, _, _} = ast} ->
        partial_docs = extract_from_module_ast(ast)

        Enum.map(partial_docs, fn %{text: text, title: title} ->
          Map.merge(doc_attrs(), %{
            text: text,
            url: url,
            package: module,
            title: title,
            version: version
          })
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
    Enum.reverse(extract_docs_and_defs(lines, nil, []))
  end

  defp extract_from_module_ast({:defmodule, _, [_name, [do: single]]}) do
    Enum.reverse(extract_docs_and_defs([single], nil, []))
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

  # A def node is `{:def | :defp, meta, [head | maybe_body]}`; the head may
  # be wrapped in a `when` guard. Name and arity both come from the bare head:
  # `{name, meta, args}`, where `args` is nil for a zero-arity call.
  defp extract_name(fun), do: fun |> bare_head() |> head_name()
  defp extract_arity(fun), do: fun |> bare_head() |> head_arity()

  defp bare_head({_, _, [{:when, _, [head | _guards]} | _]}), do: head
  defp bare_head({_, _, [head | _]}), do: head

  defp head_name({{:unquote, _, [name]}, _, _}), do: name
  defp head_name({name, _, _}), do: name

  defp head_arity({_name, _, args}) when is_list(args), do: length(args)
  defp head_arity({_name, _, _}), do: 0

  defp extract_doc(doc) when is_binary(doc), do: doc
  defp extract_doc([doc]), do: extract_doc(doc)

  defp extract_doc(doc) when is_list(doc) do
    Enum.map_join(doc, fn {atom, string} ->
      "#{atom}: #{string}\n"
    end) <> "\n"
  end

  defp extract_doc(_), do: nil
end
