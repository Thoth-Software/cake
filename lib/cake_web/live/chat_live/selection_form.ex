defmodule CakeWeb.ChatLive.SelectionForm do
  @moduledoc """
  Embedded-schema form backing the manual document-selection UI. Validates that
  the submitted ids are a non-empty subset of the candidate document ids.
  """

  use Cake.Schema

  import Ecto.Changeset

  @typedoc "A manual selection: the chosen candidate document ids."
  @type t :: %__MODULE__{
          selected_doc_ids: [String.t()]
        }

  @primary_key false
  embedded_schema do
    field :selected_doc_ids, {:array, :string}, default: []
  end

  @doc """
  Casts and validates a manual document selection: blank ids are dropped
  first, then `:selected_doc_ids` must be a non-empty subset of
  `available_doc_ids`, the candidate document ids the UI offered.

  The non-empty check reads the field, not the changes: an empty submission
  (no ids, or only blank ones) is no change from the struct's `[]` default,
  so `validate_length/3` would never see it and the form would pass as
  "nothing changed".
  """
  @spec changeset(map(), [String.t()]) :: Ecto.Changeset.t()
  def changeset(attrs, available_doc_ids) do
    attrs = filter_empty_doc_ids(attrs)

    %__MODULE__{}
    |> cast(attrs, [:selected_doc_ids])
    |> validate_non_empty_selection()
    |> validate_subset(:selected_doc_ids, available_doc_ids)
    |> sanitize_text_fields()
  end

  # nil counts as empty too: no form submits it, but a hand-crafted event or
  # a programmatic caller can, and nil would otherwise slip past both checks.
  defp validate_non_empty_selection(changeset) do
    if get_field(changeset, :selected_doc_ids) in [nil, []] do
      add_error(changeset, :selected_doc_ids, "should have at least %{count} item(s)",
        count: 1,
        validation: :length,
        kind: :min,
        type: :list
      )
    else
      changeset
    end
  end

  defp filter_empty_doc_ids(%{"selected_doc_ids" => ids} = attrs) when is_list(ids) do
    %{attrs | "selected_doc_ids" => Enum.reject(ids, &(&1 == ""))}
  end

  defp filter_empty_doc_ids(%{"selected_doc_ids" => nil} = attrs) do
    %{attrs | "selected_doc_ids" => []}
  end

  defp filter_empty_doc_ids(attrs), do: attrs
end
