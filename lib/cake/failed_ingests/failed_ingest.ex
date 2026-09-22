defmodule Cake.FailedIngests.FailedIngest do
  @moduledoc """
  Ecto schema for an item-level ingest failure. Records which pipeline and step
  failed, the offending input, and retry bookkeeping so the sweep machinery can
  later re-attempt the item.

  `run_id` is the `Cake.Pipelines.Context.run_id` of the ingest run that
  recorded the failure. Concurrent runs of the same pipeline, implementation,
  and version share those three identity fields, so run-scoped counting and
  sweeping key on `run_id` instead. It is required on every new row; rows
  recorded before the column existed load with `run_id: nil` and are
  historical records outside the run-scoped sweep.
  """

  use Cake.Schema
  import Ecto.Changeset

  schema "failed_ingests" do
    field :run_id, :binary_id
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

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          run_id: Ecto.UUID.t() | nil,
          pipeline_behaviour: String.t(),
          pipeline_implementation: String.t(),
          step: String.t(),
          version: String.t(),
          error_text: String.t(),
          input_identifier: String.t() | nil,
          pipeline_fatal: boolean(),
          retry_count: integer() | nil,
          last_retried_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc false
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(failed_ingest, attrs) do
    failed_ingest
    |> cast(attrs, [
      :run_id,
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
      :run_id,
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
