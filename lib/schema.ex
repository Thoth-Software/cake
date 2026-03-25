defmodule Caque.Schema do
  @moduledoc """
  Enforces the use of UUIDs for primary keys and relationships.
  """

  @callback doc_attrs() :: map()
  @optional_callbacks [doc_attrs: 0]

  # If we want to add more schemas in the future that are technical docs similar in structure to programming language docs, then this schema is fine as-is
  # However, if we want to add things with structure very different to technical docs, then we will have to change our approach
  # Most likely, we will define submodules, Caque.Schema.SubModule, each of which `use`s Caque.Schema and then defines whatever callbacks it defines
  # Caque.Schema will have attributes common to all schemas

  defmacro __using__(_opts \\ []) do
    quote do
      use Ecto.Schema

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id
      @behaviour Caque.Schema
    end
  end
end
