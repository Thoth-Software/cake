defmodule Cake.Documents.ParsedDocumentPropertyTest do
  @moduledoc """
  Property tests for `Cake.Documents.ParsedDocument` changeset sanitization.

  `sanitize_text_fields/1` (defined by `use Cake.Schema`) strips NUL bytes
  from string fields. These properties pin the invariants against arbitrary
  unicode input.
  """

  use Cake.DataCase, async: true
  use ExUnitProperties

  alias Cake.Documents.ParsedDocument

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  # Strings that may contain interleaved NUL bytes — exactly the input that
  # exercises the sanitizer's filtering branch.
  defp string_with_nuls do
    gen all(parts <- list_of(one_of([string(:utf8, max_length: 8), constant("\0")]), max_length: 16)) do
      Enum.join(parts)
    end
  end

  # All string fields get a non-empty suffix so Ecto's cast doesn't
  # collapse them to nil via :empty_values — that's upstream of
  # sanitize_text_fields/1 and not what these properties are testing.
  @field_suffixes %{
    source: "src",
    version: "1.0",
    package: "pkg",
    url: "https://example.com",
    title: "t",
    language: "l",
    text: "x"
  }

  defp valid_attrs do
    fields =
      Enum.map(@field_suffixes, fn {field, suffix} ->
        gen all(prefix <- string_with_nuls()) do
          {field, prefix <> suffix}
        end
      end)

    gen all(values <- fixed_list(fields), core <- boolean()) do
      Map.new([{:core, core} | values])
    end
  end

  defp apply_changes!(attrs) do
    %ParsedDocument{}
    |> ParsedDocument.changeset(attrs)
    |> Ecto.Changeset.apply_changes()
  end

  # The :string-typed fields of the schema, captured here so the assertions
  # can iterate over them without re-deriving via reflection.
  defp string_fields do
    [:source, :version, :package, :url, :title, :language, :text]
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "no string field in the applied changeset contains a NUL byte" do
    check all(attrs <- valid_attrs()) do
      doc = apply_changes!(attrs)

      Enum.each(string_fields(), fn field ->
        case Map.get(doc, field) do
          nil -> :ok
          value when is_binary(value) -> refute String.contains?(value, "\0")
        end
      end)
    end
  end

  property "sanitize is idempotent — running the changeset twice yields equal applied values" do
    check all(attrs <- valid_attrs()) do
      once = apply_changes!(attrs)

      twice =
        once
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at, :embedding])
        |> apply_changes!()

      Enum.each(string_fields(), fn field ->
        assert Map.get(once, field) == Map.get(twice, field)
      end)
    end
  end

  property "non-NUL characters are preserved (output equals input with NULs removed)" do
    check all(attrs <- valid_attrs()) do
      doc = apply_changes!(attrs)

      Enum.each(string_fields(), fn field ->
        case Map.get(attrs, field) do
          nil ->
            :ok

          input when is_binary(input) ->
            expected = String.replace(input, "\0", "")
            assert Map.get(doc, field) == expected
        end
      end)
    end
  end
end
