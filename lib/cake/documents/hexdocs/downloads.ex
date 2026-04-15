defmodule Cake.Documents.Hexdocs.Downloads do
  @moduledoc """
  Fetches and extracts documentation tarballs from hex.pm for Elixir core docs.
  """

  @dir System.tmp_dir!() <> "hexdocs/"

  @spec clone_and_get_module_paths(String.t()) :: [String.t()]
  def clone_and_get_module_paths(version) do
    File.mkdir_p(@dir)
    System.cmd("git", ["clone", "https://github.com/elixir-lang/elixir.git", @dir])
    System.cmd("git", ["checkout v#{version}"])

    "elixir/lib/elixir/lib"
    |> list_files()
    |> List.flatten()
    |> Enum.filter(fn filename -> String.ends_with?(filename, ".ex") end)
    |> Enum.map(fn relative_file_path ->
      Path.join([@dir, relative_file_path])
    end)
  end

  @doc """
  Downloads the documentation tarball for the given version and saves it to disk.

  Returns `{:ok, file_path}` or `{:error, reason}`.
  """
  @spec download_tarball(String.t()) :: {:ok, String.t()} | {:error, any()}
  def download_tarball(version) do
    File.mkdir_p(@dir)
    url = "https://repo.hex.pm/docs/elixir-#{version}.tar.gz"
    tar_path = Path.join(@dir, "elixir-#{version}.tar.gz")

    case Req.get(url, raw: true) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {File.write(tar_path, body), tar_path}

      {:ok, %Req.Response{status: code}} ->
        File.rm_rf!(@dir)
        {:error, "Failed with status #{code} \n Files removed:"}

      {:error, %{reason: reason}} ->
        File.rm_rf!(@dir)
        {:error, reason}
    end
  end

  @spec html_file_paths({:ok, String.t()} | {term(), term()}) :: {:ok, [String.t()]} | term()
  def html_file_paths({:ok, tar_path}) do
    :erl_tar.extract(tar_path, [:compressed, {:cwd, @dir}, :verbose])

    paths =
      @dir
      |> File.ls!()
      |> Enum.filter(fn filename ->
        String.ends_with?(filename, ".html") && not String.ends_with?(filename, "index.html")
      end)
      |> Enum.map(fn relative_file_path ->
        Path.join([@dir, relative_file_path])
      end)

    {:ok, paths}
  end

  def html_file_paths({error_tuple, _}), do: error_tuple

  @spec list_files(String.t()) :: [String.t()]
  def list_files(""), do: []

  def list_files(dir) do
    ls = File.ls!(dir)
    {directories, files} = Enum.split_with(ls, &File.dir?/1)

    [files | Enum.flat_map(directories, &list_files/1)]
  end
end
