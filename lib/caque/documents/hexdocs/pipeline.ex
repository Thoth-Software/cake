defmodule Caque.Documents.Hexdocs.Pipeline do
  @moduledoc """
  Implements the document ingestion pipeline for hexdocs.
  """

  require Logger
  alias Caque.Documents.Hexdocs
  alias Caque.Documents.Hexdocs.Hexdoc
  alias Caque.Documents.Hexdocs.Downloads

  @behaviour Caque.Documents.Pipeline
  @type version :: Caque.Documents.Pipeline.version()

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
      |> Task.async_stream(&to_hexdoc(&1, version),
        max_concurrency: 4,
        timeout: :infinity
      )
      #This is godawful. We need to deep-six this call to Caque.Repo.Insert in favor of an actual context function with an actual changeset.
      #Not newing up a new struct from scratch like some kind of idiot.
      |> Enum.map(fn
        {:ok, struct} -> Caque.Repo.insert(struct, log: false)
        {:exit, reason} -> Logger.warn("Failed: #{inspect(reason)}")
      end)

      :ok
  end

  @impl true
  def parse(version) do
    version
    |> Hexdocs.hexdocs_by_version()
    |> Task.async_stream(
      &Hexdoc.to_parsed_docs/1,
      max_concurrency: 4,
      timeout: 30_000
    )
    |> Stream.flat_map(fn tuple ->
      case tuple do
      {:ok, parsed_docs} -> parsed_docs
      {:error, _} -> []
        end
    end)
  end

  @impl true
  def source(), do: Hexdoc.doc_attrs().source

  def to_hexdoc(path, version) do
    url_suffix =
      path
      |> String.split("/")
      |> List.last()

    url = "https://hexdocs.pm/elixir/#{url_suffix}"
    module = String.replace(url_suffix, ".html", "")

    content = File.read!(path)

    %Caque.Documents.Hexdocs.Hexdoc{
      module: module,
      version: version,
      # core: core,
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
