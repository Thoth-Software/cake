defmodule CakeWeb.ChatLive.QuestionForm do
  @moduledoc """
  Embedded-schema form backing the chat question input. Validates that a
  question and a mode (`:auto` or `:manual`) are present.
  """

  use Cake.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          question: String.t() | nil,
          mode: :auto | :manual | nil
        }

  @primary_key false
  embedded_schema do
    field :question, :string
    field :mode, Ecto.Enum, values: [:auto, :manual]
  end

  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:question, :mode])
    |> validate_required([:question, :mode])
    |> validate_length(:question, min: 1)
    |> sanitize_text_fields()
  end
end
