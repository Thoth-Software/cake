defmodule Cake.Books.Adapters.Disk do
  @moduledoc """
  Filesystem-backed storage adapter for book binaries.

  Reads and writes files using the key as a path relative to the configured
  root directory. Suitable for development and testing.
  """

  @behaviour Cake.Books.Adapters

  @spec root() :: String.t()
  defp root do
    Application.get_env(:cake, :book_storage_root, "priv/book_storage")
  end

  @impl Cake.Books.Adapters
  @spec read(Cake.Books.Adapters.key()) :: {:ok, binary()} | {:error, term()}
  def read(key) do
    key
    |> full_path()
    |> File.read()
  end

  @impl Cake.Books.Adapters
  @spec write(Cake.Books.Adapters.key(), binary()) :: :ok | {:error, term()}
  def write(key, binary) do
    path = full_path(key)

    with :ok <- path |> Path.dirname() |> File.mkdir_p() do
      File.write(path, binary)
    end
  end

  @impl Cake.Books.Adapters
  @spec exists?(Cake.Books.Adapters.key()) :: boolean()
  def exists?(key) do
    key
    |> full_path()
    |> File.exists?()
  end

  @impl Cake.Books.Adapters
  @spec delete(Cake.Books.Adapters.key()) :: :ok | {:error, term()}
  def delete(key) do
    case File.rm(full_path(key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec full_path(Cake.Books.Adapters.key()) :: String.t()
  defp full_path(key) do
    Path.join(root(), key)
  end
end
