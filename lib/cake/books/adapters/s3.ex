defmodule Cake.Books.Adapters.S3 do
  @moduledoc """
  S3-backed storage adapter for book binaries.

  Delegates to ExAws for all operations. Authentication is handled via IAM
  role — no explicit credentials in application config.

  Currently reads entire objects into memory. For very large documents,
  streaming via `ExAws.S3.download_file/4` or multipart reads may be
  warranted in the future.
  """

  @behaviour Cake.Books.Adapters

  @spec bucket() :: String.t()
  defp bucket do
    Application.fetch_env!(:cake, :book_storage_s3_bucket)
  end

  @impl Cake.Books.Adapters
  @spec read(Cake.Books.Adapters.key()) :: {:ok, binary()} | {:error, term()}
  def read(key) do
    case bucket() |> ExAws.S3.get_object(key) |> ExAws.request() do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Cake.Books.Adapters
  @spec write(Cake.Books.Adapters.key(), binary()) :: :ok | {:error, term()}
  def write(key, binary) do
    case bucket() |> ExAws.S3.put_object(key, binary) |> ExAws.request() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Cake.Books.Adapters
  @spec exists?(Cake.Books.Adapters.key()) :: boolean()
  def exists?(key) do
    case bucket() |> ExAws.S3.head_object(key) |> ExAws.request() do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @impl Cake.Books.Adapters
  @spec delete(Cake.Books.Adapters.key()) :: :ok | {:error, term()}
  def delete(key) do
    case bucket() |> ExAws.S3.delete_object(key) |> ExAws.request() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
