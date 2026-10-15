defmodule Cake.Documents.Hexdocs.Pipeline do
  @moduledoc """
  Implements the document ingestion pipeline for hexdocs.

  `to_hexdoc_attrs/2` is public so tests can drive that stage directly. It
  is `@doc false`: not part of the API.
  """

  @behaviour Cake.Documents.Pipeline

  import Ecto.Query, warn: false
  alias Cake.Documents.Hexdocs.Hexdoc
  alias Cake.Pipelines
  alias Cake.Pipelines.Context
  alias Cake.Repo

  @typedoc "A source release; the same type as `t:Cake.Documents.Pipeline.version/0`."
  @type version :: Cake.Documents.Pipeline.version()

  @impl Cake.Documents.Pipeline
  @spec success_message(Context.t()) :: String.t()
  def success_message(%Context{version: version}),
    do: "Successfully ingested Elixir docs from Hexdocs for version #{version}"

  @dir Path.join(System.tmp_dir!(), "hexdocs/")
  @source_repo "https://github.com/elixir-lang/elixir.git"

  @impl Cake.Documents.Pipeline
  @spec download(Context.t()) :: {:ok, [String.t()]} | {:error, :download, any()}
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
             @source_repo,
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
        {:error, :download, "git clone failed with exit status #{exit_status}"}
    end
  end

  @impl Cake.Documents.Pipeline
  @spec persist_raw_docs([String.t()], Context.t()) :: Enumerable.t()
  def persist_raw_docs(file_paths, %Context{version: version} = ctx) do
    new_hexdoc_attrs_stream =
      Cake.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(
        file_paths,
        fn path -> safe_to_hexdoc_attrs(path, version) end,
        max_concurrency: 4,
        timeout: :infinity,
        zip_input_on_exit: true
      )
      |> Stream.map(&unwrap_result/1)
      |> Pipelines.detuple_with_logging("docs.persist_raw", ctx)
      |> Stream.reject(fn %{module: m, version: v} ->
        Cake.Documents.Hexdocs.hexdoc_exists?(m, v)
      end)

    Cake.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      new_hexdoc_attrs_stream,
      &insert_hexdoc/1,
      max_concurrency: 4,
      timeout: 30_000,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Stream.map(&unwrap_result/1)
    |> Pipelines.detuple_with_logging("docs.persist_raw", ctx)
  end

  @impl Cake.Documents.Pipeline
  @spec parse(Enumerable.t(), Context.t()) :: Enumerable.t()
  def parse(raw_docs_stream, %Context{} = ctx) do
    Cake.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      raw_docs_stream,
      &safe_to_parsed_docs/1,
      max_concurrency: 4,
      timeout: 30_000,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Stream.map(&unwrap_result/1)
    |> Pipelines.detuple_with_logging("docs.parse", ctx)
    |> Stream.flat_map(fn parsed_docs -> parsed_docs end)
  end

  # Each task returns {:ok, value} | {:error, {identifier, message}}; the two
  # that only compute (safe_to_hexdoc_attrs/2, safe_to_parsed_docs/1) rescue
  # their own exceptions into that shape. A failed item becomes a persisted
  # FailedIngest via detuple_with_logging. A task the stream killed on timeout,
  # or one that crashed (insert_hexdoc/1 on a Postgres error, say), surfaces
  # as {:exit, {input, reason}}: the tasks run unlinked under
  # Cake.TaskSupervisor, so a crash never reaches the consumer, and
  # zip_input_on_exit names the input it died on.
  defp unwrap_result({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap_result({:ok, {:error, reason}}), do: {:error, reason}

  defp unwrap_result({:exit, {input, reason}}),
    do: {:error, {exit_identifier(input), inspect(reason)}}

  # The input a task died on: a file path (the first persist_raw_docs/2
  # stage), a hexdoc attrs map (the second), or a %Hexdoc{} (parse/2).
  defp exit_identifier(path) when is_binary(path), do: path
  defp exit_identifier(input), do: hexdoc_identifier(input)

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

  defp hexdoc_identifier(%{module: module}), do: to_string(module || "unknown")
  defp hexdoc_identifier(_other), do: "unknown"

  defp changeset_module(changeset),
    do: to_string(Ecto.Changeset.get_field(changeset, :module) || "unknown")

  @doc false
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
  @spec retry_from_raw(String.t(), String.t()) ::
          {:ok, [map()]} | {:error, {:raw_doc_not_found, String.t()}}
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
