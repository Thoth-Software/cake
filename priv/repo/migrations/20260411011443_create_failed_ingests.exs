defmodule Cake.Repo.Migrations.CreateFailedIngests do
  use Ecto.Migration

  def change do
    create table(:failed_ingests, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :pipeline_behaviour, :string
      add :pipeline_implementation, :string
      add :step, :string
      add :version, :string
      add :error_text, :text
      add :input_identifier, :string
      add :pipeline_fatal, :boolean, default: false, null: false
      add :retry_count, :integer, default: 0
      add :last_retried_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end
  end
end
