defmodule Cake.Documents.Hexdocs.Pipeline do
  @moduledoc """
  Implements the document ingestion pipeline for hexdocs.
  """

  @behaviour Cake.Documents.Pipeline

  import Ecto.Query, warn: false
  alias Cake.Documents.Hexdocs.Hexdoc
  alias Cake.Pipelines
  alias Cake.Pipelines.Context
  alias Cake.Repo

  require Logger

  @type version :: Cake.Documents.Pipeline.version()

  @impl Cake.Documents.Pipeline
  def success_message(%Context{version: version}),
    do: "Successfully ingested Elixir docs from Hexdocs for version #{version}"

  @dir Path.join(System.tmp_dir!(), "hexdocs/")

  @impl Cake.Documents.Pipeline
  def download(%{version: version}) do
    _ = File.rm_rf!(@dir)
    _ = File.mkdir_p(@dir)

    case System.cmd(
           "git",
           [
             "clone",
             "-b",
             "v#{version}",
             "--single-branch",
             "https://github.com/elixir-lang/elixir.git",
             @dir
           ],
           env: []
         ) do
      {_, 0} ->
        paths =
          @dir
          |> Path.join("lib/elixir/lib")
          |> Path.expand()
          |> list_files()
          |> List.flatten()
          |> Enum.filter(fn filename -> String.ends_with?(filename, ".ex") end)

        # |> Enum.map(fn relative_file_path ->
        #   Path.join([@dir, relative_file_path])
        # end)

        {:ok, paths}

      {_, exit_status} ->
        {:error, "git clone failed with exit status #{exit_status}"}
    end
  end

  @impl Cake.Documents.Pipeline
  def persist_raw_docs(file_paths, %Context{version: version} = ctx) do
    file_paths
    |> Task.async_stream(fn path -> safe_to_hexdoc_attrs(path, version) end,
      max_concurrency: 4,
      timeout: :infinity
    )
    |> Stream.map(&unwrap_result/1)
    |> Pipelines.detuple_with_logging("docs.persist_raw", ctx)
    |> Task.async_stream(&insert_hexdoc/1,
      max_concurrency: 4,
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Stream.map(&unwrap_result/1)
    |> Pipelines.detuple_with_logging("docs.persist_raw", ctx)
  end

  @impl Cake.Documents.Pipeline
  def parse(raw_docs_stream, %Context{} = ctx) do
    raw_docs_stream
    |> Task.async_stream(&safe_to_parsed_docs/1,
      max_concurrency: 4,
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Stream.map(&unwrap_result/1)
    |> Pipelines.detuple_with_logging("docs.parse", ctx)
    |> Stream.flat_map(fn parsed_docs -> parsed_docs end)
  end

  # Each task closure returns {:ok, value} | {:error, {identifier, message}} and
  # never raises (a plain Task.async_stream would otherwise crash the caller on a
  # raised exception). A failed item becomes a persisted FailedIngest via
  # detuple_with_logging; a killed task (timeout) surfaces as {:exit, reason}.
  defp unwrap_result({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap_result({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_result({:exit, reason}), do: {:error, {nil, inspect(reason)}}

  defp safe_to_hexdoc_attrs(path, version) do
    {:ok, to_hexdoc_attrs(path, version)}
  rescue
    e -> {:error, {path, Exception.message(e)}}
  end

  defp insert_hexdoc(attrs) do
    case Cake.Documents.Hexdocs.create_hexdoc(attrs) do
      {:ok, hexdoc} -> {:ok, hexdoc}
      {:error, changeset} -> {:error, {changeset_module(changeset), inspect(changeset)}}
    end
  end

  defp safe_to_parsed_docs(hexdoc) do
    {:ok, Hexdoc.to_parsed_docs(hexdoc)}
  rescue
    e -> {:error, {hexdoc_identifier(hexdoc), Exception.message(e)}}
  end

  defp hexdoc_identifier(%Hexdoc{module: module}), do: to_string(module || "unknown")
  defp hexdoc_identifier(_other), do: "unknown"

  defp changeset_module(changeset),
    do: to_string(Ecto.Changeset.get_field(changeset, :module) || "unknown")

  @impl Cake.Documents.Pipeline
  def source(), do: Hexdoc.doc_attrs().source

  @spec to_hexdoc_attrs(String.t(), String.t()) :: map()
  def to_hexdoc_attrs(path, version) do
    url_suffix =
      path
      |> String.split("/")
      |> List.last()

    url = "https://hexdocs.pm/elixir/#{url_suffix}"
    module = String.replace(url_suffix, ".html", "")

    content = File.read!(path)

    %{
      module: module,
      version: version,
      url: url,
      content: content
    }
  end

  @impl Cake.Documents.Pipeline
  def retry_from_raw(input_identifier, version) do
    [module_name | _] = String.split(input_identifier, "@")

    case Repo.one(
           from h in Hexdoc,
             where: h.module == ^module_name and h.version == ^version
         ) do
      nil -> {:error, {:raw_doc_not_found, input_identifier}}
      hexdoc -> {:ok, Hexdoc.to_parsed_docs(hexdoc)}
    end
  end

  @spec list_files(String.t()) :: [String.t()]
  def list_files(path) do
    all_paths =
      path
      |> File.ls!()
      |> Enum.map(&Path.join(path, &1))

    {directories, files} = Enum.split_with(all_paths, &File.dir?/1)

    Enum.flat_map(directories, &list_files/1) ++ files
  end
end
