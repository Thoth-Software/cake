defmodule Cake.Documents.Hexdocs.Pipeline do
  @moduledoc """
  Implements the document ingestion pipeline for hexdocs.
  """

  require Logger
  alias Cake.Documents.Hexdocs.Hexdoc

  @behaviour Cake.Documents.Pipeline
  alias Cake.Pipelines
  @type version :: Cake.Documents.Pipeline.version()

  @impl true
  def success_message(version),
    do: "Successfully ingested Elixir docs from Hexdocs for version #{version}"

  @dir Path.join(System.tmp_dir!(), "hexdocs/")

  @doc """
  Creates a new document in the index. The ID will be assigned automatically.
  """
  def add() do
    :whee!
  end

  @impl true
  def download(version) do
    File.rm_rf!(@dir)
    File.mkdir_p(@dir)

    System.cmd("git", [
      "clone",
      "-b",
      "v#{version}",
      "--single-branch",
      "https://github.com/elixir-lang/elixir.git",
      @dir
    ])
    |> case do
      {_, 0} ->
        Path.join(@dir, "lib/elixir/lib") |> Path.expand() |> File.ls()

        paths =
          Path.join(@dir, "lib/elixir/lib")
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

  # What the fuck does this function even return!?
  @impl true
  def persist_raw_docs(file_paths, version) do
    file_paths
    |> Task.async_stream(&to_hexdoc_attrs(&1, version),
      max_concurrency: 4,
      timeout: :infinity
    )
    |> Pipelines.detuple()
    |> Task.async_stream(&Cake.Documents.Hexdocs.create_hexdoc/1)
    |> Pipelines.detuple()
  end

  @impl true
  def parse(raw_docs_stream) do
    raw_docs_stream
    |> Task.async_stream(
      &Hexdoc.to_parsed_docs/1,
      max_concurrency: 4,
      timeout: 30_000
    )
    |> Pipelines.detuple()
    |> Stream.flat_map(fn item -> item end)
  end

  @impl true
  def source(), do: Hexdoc.doc_attrs().source

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

  def list_files(path) do
    all_paths =
      path
      |> File.ls!()
      |> Enum.map(&Path.join(path, &1))

    {directories, files} = Enum.split_with(all_paths, &File.dir?/1)

    Enum.flat_map(directories, &list_files/1) ++ files
  end
end
