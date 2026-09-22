defmodule Cake.Repo.Migrations.AddRunIdToFailedIngests do
  use Ecto.Migration

  # Nullable so rows recorded before per-run isolation still load; every new
  # row gets one from the changeset's validate_required. Pre-existing rows
  # keep run_id = NULL deliberately: no run can claim them, so the run-scoped
  # count_failures/1 and sweep/3 never see them. They stay listable via
  # FailedIngests.list_failed_ingests/0 as historical records, which is all
  # any production path ever did with them (nothing calls ingest_with_sweep/5).
  def change do
    alter table(:failed_ingests) do
      add :run_id, :uuid
    end

    create index(:failed_ingests, [:run_id])
  end
end
