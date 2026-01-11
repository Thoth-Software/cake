defmodule Cake.Schema do
  @moduledoc """
  Enforces the use of UUIDs for primary keys and relationships.
  """

  # If we want to add more schemas in the future that are technical docs similar in structure to programming language docs, then this schema is fine as-is
  # However, if we want to add things with structure very different to technical docs, then we will have to change our approach
  # Most likely, we will define submodules, Cake.Schema.SubModule, each of which `use`s Cake.Schema and then defines whatever callbacks it defines
  # Cake.Schema will have attributes common to all schemas

  defmacro __using__(_opts \\ []) do
    quote do
      use Ecto.Schema
      import Ecto.Query

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id
    end
  end
end
