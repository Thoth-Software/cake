defmodule Cake.Repo.Migrations.AddRunIdToFailedIngests do
  use Ecto.Migration

  # Nullable so rows recorded before per-run isolation still load; every new
  # row gets one from the changeset's validate_required.
  def change do
    alter table(:failed_ingests) do
      add :run_id, :uuid
    end

    create index(:failed_ingests, [:run_id])
  end
end
