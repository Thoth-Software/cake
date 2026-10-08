defmodule Cake.SchemaPropertyTest do
  @moduledoc """
  Property tests for `Cake.Schema.sanitize_text_fields/2`, over every schema
  that uses `Cake.Schema`.

  The helper is generic: it reflects over the schema's fields and strips NUL
  bytes from every `:string` change. So the properties are generic too. The
  schema list is explicit, and a guard test fails when a module in `lib/`
  gains `use Cake.Schema` without being added here. Attrs are built by the
  same reflection the helper uses, with NULs injected into each `:string`
  field and plain values in the other castable fields, so the "untouched"
  assertion has something to look at (`SelectionForm`, whose only field is
  `{:array, :string}`, is the no-op branch the helper's moduledoc describes).

  Two layers: the helper itself, applied to a bare `cast/3` of every schema;
  and the wiring, each schema's own changeset entry point, which must run the
  helper. `UserToken` has no changeset of its own, so it appears only in the
  first layer.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cake.Accounts.User
  alias Cake.Accounts.UserToken
  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Documents.Hexdocs.Hexdoc
  alias Cake.Documents.ParsedDocument
  alias Cake.FailedIngests.FailedIngest
  alias CakeWeb.ChatLive.QuestionForm
  alias CakeWeb.ChatLive.SelectionForm

  @schemas [
    User,
    UserToken,
    Chunk,
    ParsedBook,
    Hexdoc,
    ParsedDocument,
    FailedIngest,
    QuestionForm,
    SelectionForm
  ]

  # Every schema with a changeset entry point of its own; UserToken has none.
  @wired_schemas @schemas -- [UserToken]

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  # Strings with interleaved NUL bytes and a non-empty suffix, so Ecto's cast
  # never collapses the value to nil before the sanitiser sees it.
  defp string_with_nuls do
    gen all(
          parts <- list_of(one_of([string(:utf8, max_length: 8), constant("\0")]), max_length: 12)
        ) do
      Enum.join(parts) <> "x"
    end
  end

  defp castable_fields(schema) do
    schema.__schema__(:fields)
    |> Enum.map(&{&1, schema.__schema__(:type, &1)})
    |> Enum.filter(fn {_field, type} ->
      type in [:string, {:array, :string}, :integer, :boolean]
    end)
  end

  defp string_fields(schema) do
    for {field, :string} <- castable_fields(schema), do: field
  end

  defp value_for(:string), do: string_with_nuls()
  defp value_for({:array, :string}), do: list_of(string_with_nuls(), max_length: 3)
  defp value_for(:integer), do: integer()
  defp value_for(:boolean), do: boolean()

  defp attrs_for(schema) do
    schema
    |> castable_fields()
    |> Enum.map(fn {field, type} -> gen(all(value <- value_for(type)), do: {field, value}) end)
    |> fixed_list()
    |> StreamData.map(&Map.new/1)
  end

  defp schema_and_attrs do
    gen all(schema <- member_of(@schemas), attrs <- attrs_for(schema)) do
      {schema, attrs}
    end
  end

  defp bare_cast(schema, attrs) do
    permitted = Enum.map(castable_fields(schema), &elem(&1, 0))
    Ecto.Changeset.cast(struct(schema), attrs, permitted)
  end

  defp sanitize(schema, attrs), do: schema |> bare_cast(attrs) |> schema.sanitize_text_fields()

  defp strip_nuls(value) when is_binary(value), do: String.replace(value, "\0", "")

  # Each schema's own changeset entry point, as production calls it. Options
  # keep the entry points off the Repo (no uniqueness query, no bcrypt).
  defp entry_point(User, attrs),
    do: User.registration_changeset(%User{}, attrs, hash_password: false, validate_email: false)

  defp entry_point(QuestionForm, attrs), do: QuestionForm.changeset(attrs)

  defp entry_point(SelectionForm, attrs),
    do: SelectionForm.changeset(attrs, Map.get(attrs, :selected_doc_ids, []))

  defp entry_point(schema, attrs), do: schema.changeset(struct(schema), attrs)

  # ---------------------------------------------------------------------------
  # Guard
  # ---------------------------------------------------------------------------

  test "every module in the application that uses Cake.Schema is in the list" do
    {:ok, modules} = :application.get_key(:cake, :modules)

    users =
      modules
      |> Enum.filter(
        &(Code.ensure_loaded?(&1) and function_exported?(&1, :sanitize_text_fields, 1))
      )
      |> Enum.sort()

    assert users == Enum.sort(@schemas),
           "a schema uses Cake.Schema but is missing from @schemas: #{inspect(users -- @schemas)}"
  end

  # ---------------------------------------------------------------------------
  # The helper, over every schema
  # ---------------------------------------------------------------------------

  property "no :string change contains a NUL byte after sanitising" do
    check all({schema, attrs} <- schema_and_attrs()) do
      changeset = sanitize(schema, attrs)

      for field <- string_fields(schema) do
        value = Ecto.Changeset.get_change(changeset, field)
        assert is_binary(value) and not String.contains?(value, "\0")
      end
    end
  end

  property "every :string change equals its input with the NULs removed, so non-NUL text is preserved" do
    check all({schema, attrs} <- schema_and_attrs()) do
      changeset = sanitize(schema, attrs)

      for field <- string_fields(schema) do
        assert Ecto.Changeset.get_change(changeset, field) == strip_nuls(Map.fetch!(attrs, field))
      end
    end
  end

  property "sanitising is idempotent" do
    check all({schema, attrs} <- schema_and_attrs()) do
      once = sanitize(schema, attrs)
      assert schema.sanitize_text_fields(once).changes == once.changes
    end
  end

  property "changes to fields that are not :string are untouched (arrays of strings included)" do
    check all({schema, attrs} <- schema_and_attrs()) do
      before = bare_cast(schema, attrs)
      after_sanitise = schema.sanitize_text_fields(before)
      other_fields = Map.keys(before.changes) -- string_fields(schema)

      assert Map.take(after_sanitise.changes, other_fields) ==
               Map.take(before.changes, other_fields)
    end
  end

  # ---------------------------------------------------------------------------
  # The wiring: each schema's own changeset runs the helper
  # ---------------------------------------------------------------------------

  property "every schema's changeset entry point strips NULs from its :string changes" do
    check all(
            schema <- member_of(@wired_schemas),
            attrs <- attrs_for(schema)
          ) do
      changeset = entry_point(schema, attrs)

      for field <- string_fields(schema) do
        case Ecto.Changeset.get_change(changeset, field) do
          # A field the entry point does not cast (User casts only :email
          # and :password; :hashed_password is set by hashing) has no change.
          nil -> :ok
          value -> assert value == strip_nuls(Map.fetch!(attrs, field))
        end
      end
    end
  end
end
