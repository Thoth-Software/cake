defmodule Cake.ReleaseTest do
  # Not async: the migrator takes the lock on schema_migrations through the
  # shared sandbox connection.
  use Cake.DataCase, async: false

  alias Cake.Release

  # The test database is already migrated (the `test` alias runs ecto.migrate),
  # so both functions are exercised on their no-op paths: enough to pin the
  # shape of what they return and that they run without Mix's tasks, which is
  # how a release calls them (`bin/migrate`, `bin/cake eval`). That every
  # migration applies to an empty database from inside the release image is
  # ci/release_smoke.sh's assertion, not this file's.

  describe "migrate/0" do
    test "reports one result per configured repo and applies nothing to a migrated database" do
      # The third element is what with_repo had to start: nothing, here.
      assert Release.migrate() == [{:ok, [], []}]
    end

    test "leaves the recorded migrations as they were" do
      before = recorded_versions()

      _ = Release.migrate()

      assert recorded_versions() == before
    end
  end

  describe "rollback/2" do
    test "rolls back nothing when the target version is newer than every migration" do
      before = recorded_versions()
      newer_than_all = List.last(before) + 1

      assert Release.rollback(Cake.Repo, newer_than_all) == {:ok, [], []}
      assert recorded_versions() == before
    end
  end

  defp recorded_versions do
    Repo.all(from m in "schema_migrations", select: m.version, order_by: m.version)
  end
end
