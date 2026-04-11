defmodule Cake.FailedIngests.FailedIngest do
  use Cake.Schema
  import Ecto.Changeset

  schema "failed_ingests" do
    field :pipeline_behaviour, :string
    field :pipeline_implementation, :string
    field :step, :string
    field :version, :string
    field :error_text, :string
    field :input_identifier, :string
    field :pipeline_fatal, :boolean, default: false
    field :retry_count, :integer
    field :last_retried_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(failed_ingest, attrs) do
    failed_ingest
    |> cast(attrs, [
      :pipeline_behaviour,
      :pipeline_implementation,
      :step,
      :version,
      :error_text,
      :input_identifier,
      :pipeline_fatal,
      :retry_count,
      :last_retried_at
    ])
    |> validate_required([
      :pipeline_behaviour,
      :pipeline_implementation,
      :step,
      :version,
      :error_text,
      :pipeline_fatal
    ])
    |> sanitize_text_fields()
  end
end
