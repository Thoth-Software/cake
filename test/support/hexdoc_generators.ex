defmodule Cake.HexdocGenerators do
  @moduledoc """
  StreamData generators for `Cake.Documents.Hexdocs.Hexdoc.to_parsed_docs/1`
  property tests.

  The central generator is `module_spec/0`: a description of one Elixir module
  as a list of items, each either a function definition (`def`/`defp`, any
  arity 0..5, optional guard, optional default arguments, one to three
  clauses, an optional `@doc` before the first clause) or a non-function form
  the parser must skip (`@moduledoc`, `@spec`, `@type`, `alias`, `require`,
  `defmacro`, `defguard`, `defdelegate`). `render/1` turns a spec into source
  text, and `expected_entries/1` into the `{title, doc}` pairs the parser
  should emit for it, so a property compares the parser's output against a
  model it did not compute.

  `@doc` is attached only to function definitions, never to a skipped form:
  the parser carries a pending `@doc` forward across skipped forms, so a doc
  on a `defmacro` would attach to the next `def`. That is a quirk of the
  parser's accumulator, not a contract this module wants to pin either way.

  Sigil docs use `~S(...)`, which has no escapes, so their text is drawn from
  alphanumerics and spaces; string docs are rendered with `inspect/1`.
  """

  @typedoc "How a definition's `@doc` is written, or `nil` for no `@doc`."
  @type doc :: nil | {:string, String.t()} | {:sigil, String.t()} | {:keyword, keyword()} | false

  @typedoc "One `def`/`defp` in a module spec."
  @type definition :: %{
          item: :definition,
          kind: :def | :defp,
          name: String.t(),
          arity: 0..5,
          guard?: boolean(),
          defaults: non_neg_integer(),
          clauses: pos_integer(),
          doc: doc()
        }

  @typedoc "One form the parser must skip."
  @type skipped :: %{item: :skipped, form: String.t()}

  @typedoc "A module as an ordered list of items."
  @type module_spec :: [definition() | skipped()]

  @doc "Generates a module spec with one to eight items, at least one of them a definition."
  @spec module_spec() :: StreamData.t(module_spec())
  def module_spec do
    StreamData.filter(
      StreamData.list_of(item(), min_length: 1, max_length: 8),
      &Enum.any?(&1, fn item -> item.item == :definition end)
    )
  end

  @doc "Renders a module spec as the source text of a single bare `defmodule`."
  @spec render(module_spec()) :: String.t()
  def render(spec) do
    body = Enum.map_join(spec, "\n", &render_item/1)
    "defmodule Example do\n#{body}\nend\n"
  end

  @doc """
  The `{title, doc}` pair for every entry the parser should emit, in order:
  one per clause of every definition, the doc on the first clause only.
  """
  @spec expected_entries(module_spec()) :: [{String.t(), doc()}]
  def expected_entries(spec) do
    Enum.flat_map(spec, fn
      %{item: :definition} = definition ->
        title = "#{definition.name}/#{definition.arity}"
        rest = List.duplicate({title, nil}, definition.clauses - 1)
        [{title, definition.doc} | rest]

      %{item: :skipped} ->
        []
    end)
  end

  # ---------------------------------------------------------------------------
  # Item generators
  # ---------------------------------------------------------------------------

  defp item do
    StreamData.frequency([{3, definition()}, {1, skipped()}])
  end

  defp definition do
    StreamData.bind(StreamData.integer(0..5), fn arity ->
      StreamData.map(
        StreamData.tuple({
          StreamData.member_of([:def, :defp]),
          function_name(),
          StreamData.boolean(),
          StreamData.integer(0..arity),
          StreamData.integer(1..3),
          doc()
        }),
        fn {kind, name, guard?, defaults, clauses, doc} ->
          %{
            item: :definition,
            kind: kind,
            name: name,
            arity: arity,
            guard?: guard? and arity > 0,
            # Defaults on more than one clause need a bodyless head; keep the
            # generated source to the single-clause shape in that case.
            defaults: if(clauses == 1, do: defaults, else: 0),
            clauses: clauses,
            doc: doc
          }
        end
      )
    end)
  end

  defp skipped do
    StreamData.map(
      StreamData.member_of([
        ~s(@moduledoc "Module doc."),
        "@spec helper(integer()) :: term()",
        "@typedoc \"A type.\"\n  @type t :: term()",
        "alias Foo.Bar",
        "require Logger",
        "defmacro macro_form(x), do: x",
        "defguard guard_form(x) when is_integer(x)",
        "defdelegate delegate_form(x), to: Enum, as: :count",
        "@behaviour Access"
      ]),
      &%{item: :skipped, form: &1}
    )
  end

  # A valid, non-reserved function identifier: a leading `fun_` keeps it clear
  # of reserved words (`fn`, `false`) and starts it with a lowercase letter.
  defp function_name do
    StreamData.map(
      StreamData.tuple({
        StreamData.string(:alphanumeric, max_length: 6),
        StreamData.member_of(["", "", "?", "!"])
      }),
      fn {rest, suffix} -> "fun_" <> rest <> suffix end
    )
  end

  defp doc do
    StreamData.frequency([
      {2, StreamData.constant(nil)},
      {3, StreamData.map(doc_text(), &{:string, &1})},
      {2, StreamData.map(doc_text(), &{:sigil, &1})},
      {1, StreamData.map(keyword_doc(), &{:keyword, &1})},
      {1, StreamData.constant(false)}
    ])
  end

  # `@doc` metadata takes any term: a string value, a boolean, or a list.
  defp keyword_doc do
    value =
      StreamData.one_of([
        doc_text(),
        StreamData.boolean(),
        StreamData.list_of(StreamData.atom(:alphanumeric), max_length: 2)
      ])

    StreamData.map(
      StreamData.tuple({StreamData.member_of([:since, :deprecated, :group]), value}),
      fn {key, value} -> [{key, value}] end
    )
  end

  @doc "How a keyword doc value appears in the parsed text: strings verbatim, other terms inspected."
  @spec rendered_doc_value(term()) :: String.t()
  def rendered_doc_value(value) when is_binary(value), do: value
  def rendered_doc_value(value), do: inspect(value)

  # Alphanumerics and spaces only: safe inside `~S(...)` and `"..."` alike.
  defp doc_text do
    StreamData.map(
      StreamData.list_of(StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
        min_length: 1,
        max_length: 5
      ),
      &Enum.join(&1, " ")
    )
  end

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  defp render_item(%{item: :skipped, form: form}), do: "  " <> form

  defp render_item(%{item: :definition} = definition) do
    first = render_doc(definition.doc) <> render_clause(definition, 0)

    rest =
      if definition.clauses > 1 do
        Enum.map_join(1..(definition.clauses - 1), "\n", &render_clause(definition, &1))
      else
        ""
      end

    Enum.join(Enum.reject([first, rest], &(&1 == "")), "\n")
  end

  defp render_doc(nil), do: ""
  defp render_doc(false), do: "  @doc false\n"
  defp render_doc({:string, text}), do: "  @doc #{inspect(text)}\n"
  defp render_doc({:sigil, text}), do: "  @doc ~S(#{text})\n"

  defp render_doc({:keyword, keyword}) do
    rendered = Enum.map_join(keyword, ", ", fn {key, value} -> "#{key}: #{inspect(value)}" end)
    "  @doc #{rendered}\n"
  end

  # Clause 0 may carry defaults and a guard; later clauses of the same
  # definition vary the body so the source reads as real multi-clause code.
  defp render_clause(definition, clause_index) do
    args = Enum.map(0..(definition.arity - 1)//1, &"a#{&1}")
    defaulted = Enum.drop(args, definition.arity - definition.defaults)

    rendered_args =
      Enum.map(args, fn arg -> if arg in defaulted, do: "#{arg} \\\\ nil", else: arg end)

    head =
      case {definition.arity, clause_index} do
        {0, 0} -> definition.name
        {0, _} -> definition.name <> "()"
        _ -> "#{definition.name}(#{Enum.join(rendered_args, ", ")})"
      end

    guard = if definition.guard?, do: " when is_integer(a0)", else: ""
    body = if args == [], do: ":ok", else: "{#{Enum.join(args, ", ")}}"

    "  #{definition.kind} #{head}#{guard}, do: #{body}"
  end
end
