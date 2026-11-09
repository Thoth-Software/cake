# User-owned LawSpec adapter for laws/fakes.lawspec.
defmodule Cake.Laws.Fakes do
  @moduledoc """
  Adapts `Cake.Laws.FakeUnit` to the `cake.laws.fakes` unit.

  Each function builds a fake from generated metadata and goes through the
  real protocol functions, `Cake.Citable.metadata/1` and
  `Cake.Promptable.prompt_context/1`, so the laws check the dispatch every
  other specification relies on, not the struct's fields.
  """

  alias Cake.Laws.FakeUnit

  @doc "`Cake.Citable.metadata/1` of a fake built from `meta`, as a metadata record."
  @spec citable_metadata(LawSpec.Data.citable_meta()) :: LawSpec.Data.citable_meta()
  def citable_metadata(meta) do
    meta
    |> FakeUnit.new("")
    |> Cake.Citable.metadata()
    |> FakeUnit.to_citable_meta()
  end

  @doc "The keys of a fake's `Cake.Citable` metadata, as text, ascending."
  @spec metadata_keys(LawSpec.Data.citable_meta()) :: [binary()]
  def metadata_keys(meta) do
    meta
    |> FakeUnit.new("")
    |> Cake.Citable.metadata()
    |> Map.keys()
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
  end

  @doc "`Cake.Promptable.prompt_context/1` of a fake built from `meta` and `text`."
  @spec prompt_context(LawSpec.Data.citable_meta(), binary()) :: binary()
  def prompt_context(meta, text) do
    meta
    |> FakeUnit.new(text)
    |> Cake.Promptable.prompt_context()
  end
end
