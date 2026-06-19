defmodule Cake.Factory do
  @moduledoc "ExMachina factory for non-Ecto test structs. `import Cake.Factory` in tests that need it."

  use ExMachina.Ecto, repo: Cake.Repo

  @doc """
  Citable metadata for a `Cake.Test.ConvoChunk`. Returns the common default
  shape; pass a map or keyword list to override individual keys.

      chunk_metadata()            # %{id: "c1", label: "L", ...}
      chunk_metadata(id: "id-1")  # same, with a different id
  """
  @spec chunk_metadata(map() | keyword()) :: Cake.Citable.metadata()
  def chunk_metadata(overrides \\ %{}) do
    Map.merge(
      %{id: "c1", label: "L", preview: "p", source_ref: nil, extras: %{}},
      Map.new(overrides)
    )
  end

  # Non-Ecto test struct that flows through the whole turn pipeline. Build with
  # `build(:convo_chunk)` (never `insert/1` — it is not Ecto-backed).
  @spec convo_chunk_factory() :: Cake.Test.ConvoChunk.t()
  def convo_chunk_factory do
    %Cake.Test.ConvoChunk{
      embedding: [0.1, 0.2, 0.3],
      prompt_text: "x",
      metadata: chunk_metadata()
    }
  end
end
