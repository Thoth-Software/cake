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
      import Cake.Schema, only: [sanitize_text_fields: 2]

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id
    end
  end

  def sanitize_text_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, cs ->
      case get_change(cs, field) do
        nil -> cs
        value when is_binary(value) -> put_change(cs, field, String.replace(value, <<0>>, ""))
        _ -> cs
      end
    end)
  end
end
