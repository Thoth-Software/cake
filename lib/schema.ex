defmodule Caque.Schema do
  @moduledoc """
  Enforces the use of UUIDs for primary keys and relationships.
  """

  defmacro __using__(_opts \\ []) do
    quote do
      use Ecto.Schema

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id
    end
  end
end
