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

    test "skips rows already present for the same module and version" do
      # Write a minimal valid .ex file so to_hexdoc_attrs can read it
      path = Path.join(System.tmp_dir!(), "Kernel.ex")
      File.write!(path, "defmodule Kernel do\nend\n")
      on_exit(fn -> File.rm(path) end)

      # First run: inserts the hexdoc
      first_run = Enum.to_list(Pipeline.persist_raw_docs([path], ctx()))
      assert length(first_run) == 1

      # Second run: the same (module, version) already exists — should be skipped
      second_run = Enum.to_list(Pipeline.persist_raw_docs([path], ctx()))
      assert second_run == []

      # Only one row exists in the DB (not duplicated)
      all = Cake.Documents.Hexdocs.list_hexdocs()
      kernel_rows = Enum.filter(all, &(&1.module == "Kernel.ex" and &1.version == "1.0.0"))
      assert length(kernel_rows) == 1
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
