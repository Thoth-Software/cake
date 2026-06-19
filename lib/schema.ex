defmodule Cake.Schema do
  @moduledoc """
  Enforces the use of UUIDs for primary keys and relationships.
  Provides shared changeset helpers for all Cake schemas.
  """

  import Ecto.Changeset

  defmacro __using__(_opts \\ []) do
    quote do
      use Ecto.Schema
      import Ecto.Query

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id

      @doc """
      Strips NUL bytes from every `:string` field changed in this changeset.
      Delegates to `Cake.Schema.sanitize_text_fields/2`.
      """
      @spec sanitize_text_fields(Ecto.Changeset.t()) :: Ecto.Changeset.t()
      def sanitize_text_fields(changeset) do
        Cake.Schema.sanitize_text_fields(changeset, __MODULE__)
      end
    end
  end

  @doc """
  Strips NUL bytes from every `:string` field present in the changeset's
  changes, for the given schema `module`. Shared implementation behind the
  `sanitize_text_fields/1` helper injected by `use Cake.Schema`.

  Reflecting over `module` here (rather than inlining per schema) keeps the
  field-type check generic: a schema with no `:string` fields — e.g. one whose
  only field is `{:array, :string}` — gets a no-op instead of provably-dead code.
  """
  @spec sanitize_text_fields(Ecto.Changeset.t(), module()) :: Ecto.Changeset.t()
  def sanitize_text_fields(changeset, module) do
    string_fields =
      Enum.filter(
        module.__schema__(:fields),
        &(module.__schema__(:type, &1) == :string)
      )

    Enum.reduce(string_fields, changeset, fn field, cs ->
      case get_change(cs, field) do
        nil ->
          cs

        value when is_binary(value) ->
          put_change(cs, field, String.replace(value, <<0>>, ""))

        _ ->
          cs
      end
    end)
  end
end
