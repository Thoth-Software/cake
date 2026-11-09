# User-owned support module, shared by the adapters (see lawspec/README.md).
defmodule Cake.Laws.FakeUnit do
  @moduledoc """
  A retrieval unit for adapters to hand to Cake code that dispatches through
  `Cake.Citable` and `Cake.Promptable` (`Citations`, `Responses`,
  `Candidates`, `Prompt`, `Conversation`).

  It carries generated data and gives it back through both protocols
  unchanged: `Cake.Citable.metadata/1` returns `metadata` as it is, and
  `Cake.Promptable.prompt_context/1` returns `prompt_context`. The
  `cake.laws.fakes` specification (`laws/fakes.lawspec`) pins both, and the
  five-key `Citable` contract, so a specification that uses the fake tests
  Cake's code and not the fake.

  Build one with `new/2` from the metadata a specification generated
  (`LawSpec.Data.CitableMeta`, from `cake.laws.shared`), or construct the
  struct directly when an adapter needs `:extras` or a non-text `:id`.
  """

  @enforce_keys [:metadata, :prompt_context]
  defstruct [:metadata, :prompt_context]

  @typedoc "A fake retrieval unit: its `Cake.Citable` metadata and its prompt text."
  @type t :: %__MODULE__{
          metadata: Cake.Citable.metadata(),
          prompt_context: String.t()
        }

  @doc """
  A fake from generated metadata and prompt text. `:extras` is empty, and
  `:source_ref` is `nil` when the metadata has none.
  """
  @spec new(LawSpec.Data.citable_meta(), String.t()) :: t()
  def new(%LawSpec.Data.CitableMeta{} = meta, prompt_context) when is_binary(prompt_context) do
    %__MODULE__{
      metadata: %{
        id: meta.id,
        label: meta.label,
        preview: meta.preview,
        source_ref: from_maybe(meta.source_ref),
        extras: %{}
      },
      prompt_context: prompt_context
    }
  end

  @doc """
  The generated metadata record for a `Cake.Citable` metadata map; the
  inverse of the metadata half of `new/2`. `:extras` is dropped, and `:id`
  must be text.
  """
  @spec to_citable_meta(Cake.Citable.metadata()) :: LawSpec.Data.citable_meta()
  def to_citable_meta(%{id: id, label: label, preview: preview, source_ref: source_ref})
      when is_binary(id) do
    %LawSpec.Data.CitableMeta{
      id: id,
      label: label,
      preview: preview,
      source_ref: to_maybe(source_ref)
    }
  end

  defp from_maybe(:absent), do: nil
  defp from_maybe({:present, value}), do: value

  defp to_maybe(nil), do: :absent
  defp to_maybe(value), do: {:present, value}
end

defimpl Cake.Citable, for: Cake.Laws.FakeUnit do
  @spec metadata(Cake.Laws.FakeUnit.t()) :: Cake.Citable.metadata()
  def metadata(%Cake.Laws.FakeUnit{metadata: metadata}), do: metadata
end

defimpl Cake.Promptable, for: Cake.Laws.FakeUnit do
  @spec prompt_context(Cake.Laws.FakeUnit.t()) :: String.t()
  def prompt_context(%Cake.Laws.FakeUnit{prompt_context: text}), do: text
end
