defmodule Cake.Documents.Hexdocs.PipelineTest do
  @moduledoc """
  Pins the failure discipline of the hexdocs pipeline: item-level failures in
  `persist_raw_docs/2` and `parse/2` are persisted as `FailedIngest`s rather
  than silently dropped (#165), and a crash inside one of their tasks is such
  a failure too, recorded with the module's name, never the end of the run
  (#273).
  """

  use Cake.DataCase, async: true

  import ExUnit.CaptureLog

  alias Cake.Documents.Hexdocs.Hexdoc
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

    test "records a raw doc whose insert task crashes and keeps persisting the rest" do
      dir = Path.join(System.tmp_dir!(), "cake-hexdocs-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      # Nothing between File.read!/1 and Repo.insert/2 checks a source file's
      # encoding, and Postgres refuses a text value that is not valid UTF-8,
      # so the insert raises Postgrex.Error inside its task.
      invalid_path = Path.join(dir, "Invalid.ex")
      File.write!(invalid_path, <<"defmodule Invalid do\nend\n", 0xFF>>)
      fine_path = Path.join(dir, "Fine.ex")
      File.write!(fine_path, "defmodule Fine do\nend\n")

      capture_log(fn ->
        assert [%Hexdoc{module: "Fine.ex"}] =
                 Enum.to_list(Pipeline.persist_raw_docs([invalid_path, fine_path], ctx()))
      end)

      assert [failure] = FailedIngests.list_failed_ingests()
      assert failure.step == "docs.persist_raw"
      assert failure.input_identifier == "Invalid.ex"
      assert failure.error_text =~ "Postgrex.Error"
      assert failure.error_text =~ "UTF8"
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
