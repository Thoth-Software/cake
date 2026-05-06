defmodule CakeWeb.ChatLive.SelectionForm do
  use Ecto.Schema

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
    |> validate_subset_of(:selected_doc_ids, available_doc_ids)
  end

  defp filter_empty_doc_ids(%{"selected_doc_ids" => ids} = attrs) when is_list(ids) do
    %{attrs | "selected_doc_ids" => Enum.reject(ids, &(&1 == ""))}
  end

  defp filter_empty_doc_ids(attrs), do: attrs

  defp validate_subset_of(changeset, field, available) do
    validate_change(changeset, field, fn _, selected ->
      if Enum.all?(selected, &(&1 in available)) do
        []
      else
        [{field, "contains IDs not in the available set"}]
      end
    end)
  end
end
