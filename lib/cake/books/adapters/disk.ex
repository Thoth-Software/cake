defmodule Cake.Books.Adapters.Disk do
  @moduledoc """
  Filesystem-backed storage adapter for book binaries.

  Reads and writes files using the key as a path relative to the configured
  root directory. Suitable for development and testing.

  Every operation first checks the key with `Cake.Books.Adapters.valid_key?/1`
  and answers `{:error, :einval}` (or `false` from `exists?/1`) for a key
  that could resolve outside the root, so no `..` segment ever reaches the
  filesystem.
  """

  @behaviour Cake.Books.Adapters

  alias Cake.Books.Adapters

  @spec root() :: String.t()
  defp root do
    Application.get_env(:cake, :book_storage_root, "priv/book_storage")
  end

  @impl Cake.Books.Adapters
  @spec read(Adapters.key()) :: {:ok, binary()} | {:error, File.posix()}
  def read(key) do
    with {:ok, path} <- full_path(key) do
      File.read(path)
    end
  end

  @impl Cake.Books.Adapters
  @spec write(Adapters.key(), binary()) :: :ok | {:error, File.posix()}
  def write(key, binary) do
    with {:ok, path} <- full_path(key),
         :ok <- path |> Path.dirname() |> File.mkdir_p() do
      File.write(path, binary)
    end
  end

  @impl Cake.Books.Adapters
  @spec exists?(Adapters.key()) :: boolean()
  def exists?(key) do
    case full_path(key) do
      {:ok, path} -> File.exists?(path)
      {:error, :einval} -> false
    end
  end

  @impl Cake.Books.Adapters
  @spec delete(Adapters.key()) :: :ok | {:error, File.posix()}
  def delete(key) do
    with {:ok, path} <- full_path(key) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec full_path(Adapters.key()) :: {:ok, String.t()} | {:error, :einval}
  defp full_path(key) do
    if Adapters.valid_key?(key) do
      {:ok, Path.join(root(), key)}
    else
      {:error, :einval}
    end
  end
end
