defmodule Cake.Documents.Hexdocs.PipelineTest do
  @moduledoc """
  Pins the failure discipline of the hexdocs pipeline: item-level failures in
  `persist_raw_docs/2` and `parse/2` are persisted as `FailedIngest`s rather
  than silently dropped (#165).
  """

  use Cake.DataCase, async: true

  alias Cake.Documents.Hexdocs.Pipeline
  alias Cake.FailedIngests
  alias Cake.Pipelines

  defp ctx do
    Pipelines.build_context(
      Cake.Documents.Pipeline,
      Cake.Documents.Hexdocs.Pipeline,
      {1, 0, 0}
    )
  end

  describe "persist_raw_docs/2" do
    test "persists a FailedIngest when a raw doc file cannot be read" do
      bad_path = "/tmp/cake-missing-#{System.unique_integer([:positive])}.ex"

      result = Enum.to_list(Pipeline.persist_raw_docs([bad_path], ctx()))

      assert result == []
      steps = Enum.map(FailedIngests.list_failed_ingests(), & &1.step)
      assert "docs.persist_raw" in steps
    end
  end

  describe "parse/2" do
    test "persists a FailedIngest when a raw doc cannot be parsed" do
      result = Enum.to_list(Pipeline.parse([:not_a_hexdoc], ctx()))

      assert result == []
      steps = Enum.map(FailedIngests.list_failed_ingests(), & &1.step)
      assert "docs.parse" in steps
    end
  end
end
