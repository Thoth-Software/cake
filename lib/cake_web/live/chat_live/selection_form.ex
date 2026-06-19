defmodule CakeWeb.ChatLive.SelectionForm do
  @moduledoc """
  Embedded-schema form backing the manual document-selection UI. Validates that
  the submitted ids are a non-empty subset of the candidate document ids.
  """

  use Cake.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          selected_doc_ids: [String.t()]
        }

  @primary_key false
  embedded_schema do
    field :selected_doc_ids, {:array, :string}, default: []
  end

  @spec changeset(map(), [String.t()]) :: Ecto.Changeset.t()
  def changeset(attrs, available_doc_ids) do
    attrs = filter_empty_doc_ids(attrs)

    %__MODULE__{}
    |> cast(attrs, [:selected_doc_ids])
    |> validate_length(:selected_doc_ids, min: 1)
    |> validate_subset(:selected_doc_ids, available_doc_ids)
    |> sanitize_text_fields()
  end

  defp filter_empty_doc_ids(%{"selected_doc_ids" => ids} = attrs) when is_list(ids) do
    %{attrs | "selected_doc_ids" => Enum.reject(ids, &(&1 == ""))}
  end

  defp filter_empty_doc_ids(attrs), do: attrs
end
