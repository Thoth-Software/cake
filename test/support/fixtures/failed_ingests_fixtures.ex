defmodule Cake.FailedIngestsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Cake.FailedIngests` context.
  """

  @doc """
  Generate a failed_ingest.
  """
  @spec failed_ingest_fixture(map()) :: Cake.FailedIngests.FailedIngest.t()
  def failed_ingest_fixture(attrs \\ %{}) do
    {:ok, failed_ingest} =
      attrs
      |> Enum.into(%{
         error_text: "some  error_text",
         input_identifier: "some  input_identifier",
         last_retried_at: ~U[2026-04-10 01:14:00Z],
         pipeline_behaviour: "some  pipeline_behaviour",
         pipeline_fatal: true,
         pipeline_implementation: "some  pipeline_implementation",
         retry_count: 42,
         step: "some  step",
         version: "some  version"
      })
      |> Cake.FailedIngests.create_failed_ingest()

    failed_ingest
  end
end
