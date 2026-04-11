defmodule Cake.FailedIngestsTest do
  use Cake.DataCase

  alias Cake.FailedIngests

  describe "failed_ingests" do
    alias Cake.FailedIngests.FailedIngest

    import Cake.FailedIngestsFixtures

    @invalid_attrs %{
      pipeline_behaviour: nil,
      pipeline_implementation: nil,
      step: nil,
      version: nil,
      error_text: nil
    }

    test "list_failed_ingests/0 returns all failed_ingests" do
      failed_ingest = failed_ingest_fixture()
      assert FailedIngests.list_failed_ingests() == [failed_ingest]
    end

    test "get_failed_ingest!/1 returns the failed_ingest with given id" do
      failed_ingest = failed_ingest_fixture()
      assert FailedIngests.get_failed_ingest!(failed_ingest.id) == failed_ingest
    end

    test "create_failed_ingest/1 with valid data creates a failed_ingest" do
      valid_attrs = %{
        pipeline_behaviour: "some pipeline_behaviour",
        pipeline_implementation: "some pipeline_implementation",
        step: "some step",
        version: "some version",
        error_text: "some error_text",
        input_identifier: "some input_identifier",
        pipeline_fatal: true,
        retry_count: 42,
        last_retried_at: ~U[2026-04-10 01:14:00Z]
      }

      assert {:ok, %FailedIngest{} = failed_ingest} = FailedIngests.create_failed_ingest(valid_attrs)
      assert failed_ingest.pipeline_behaviour == "some pipeline_behaviour"
      assert failed_ingest.pipeline_implementation == "some pipeline_implementation"
      assert failed_ingest.step == "some step"
      assert failed_ingest.version == "some version"
      assert failed_ingest.error_text == "some error_text"
      assert failed_ingest.input_identifier == "some input_identifier"
      assert failed_ingest.pipeline_fatal == true
      assert failed_ingest.retry_count == 42
      assert failed_ingest.last_retried_at == ~U[2026-04-10 01:14:00Z]
    end

    test "create_failed_ingest/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = FailedIngests.create_failed_ingest(@invalid_attrs)
    end

    test "update_failed_ingest/2 with valid data updates the failed_ingest" do
      failed_ingest = failed_ingest_fixture()

      update_attrs = %{
        pipeline_behaviour: "some updated pipeline_behaviour",
        pipeline_implementation: "some updated pipeline_implementation",
        step: "some updated step",
        version: "some updated version",
        error_text: "some updated error_text",
        input_identifier: "some updated input_identifier",
        pipeline_fatal: false,
        retry_count: 43,
        last_retried_at: ~U[2026-04-11 01:14:00Z]
      }

      assert {:ok, %FailedIngest{} = failed_ingest} =
               FailedIngests.update_failed_ingest(failed_ingest, update_attrs)

      assert failed_ingest.pipeline_behaviour == "some updated pipeline_behaviour"
      assert failed_ingest.pipeline_implementation == "some updated pipeline_implementation"
      assert failed_ingest.step == "some updated step"
      assert failed_ingest.version == "some updated version"
      assert failed_ingest.error_text == "some updated error_text"
      assert failed_ingest.input_identifier == "some updated input_identifier"
      assert failed_ingest.pipeline_fatal == false
      assert failed_ingest.retry_count == 43
      assert failed_ingest.last_retried_at == ~U[2026-04-11 01:14:00Z]
    end

    test "update_failed_ingest/2 with invalid data returns error changeset" do
      failed_ingest = failed_ingest_fixture()
      assert {:error, %Ecto.Changeset{}} = FailedIngests.update_failed_ingest(failed_ingest, @invalid_attrs)
      assert failed_ingest == FailedIngests.get_failed_ingest!(failed_ingest.id)
    end

    test "delete_failed_ingest/1 deletes the failed_ingest" do
      failed_ingest = failed_ingest_fixture()
      assert {:ok, %FailedIngest{}} = FailedIngests.delete_failed_ingest(failed_ingest)
      assert_raise Ecto.NoResultsError, fn -> FailedIngests.get_failed_ingest!(failed_ingest.id) end
    end

    test "change_failed_ingest/1 returns a failed_ingest changeset" do
      failed_ingest = failed_ingest_fixture()
      assert %Ecto.Changeset{} = FailedIngests.change_failed_ingest(failed_ingest)
    end
  end
end
