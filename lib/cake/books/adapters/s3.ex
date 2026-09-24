defmodule Cake.Books.Adapters.S3 do
  @moduledoc """
  S3-backed storage adapter for book binaries.

  Delegates to ExAws for all operations: the bucket is
  `:book_storage_s3_bucket` (`config/runtime.exs`, from
  `BOOK_STORAGE_S3_BUCKET`), the region and endpoint are ExAws's `:s3`
  service config, and requests go through Req (`config :ex_aws,
  http_client: ExAws.Request.Req` in `config/config.exs`; ExAws's own
  default, hackney, is not a dependency).

  ## Authentication

  Production assumes an IAM role: no credentials in application config, so
  ExAws falls through to its instance-role provider at run time. The
  integration suite has no instance role to fall through to, so
  `Cake.S3IntegrationCase` writes a fixed key pair into the same `:ex_aws,
  :s3` config seam for the duration of each test, together with the
  endpoint of the store it targets. That is the only difference between what
  the suite exercises and what production runs.

  ## Errors

  Every callback returns whatever `ExAws.request/1` hands back, unchanged:
  `{:error, {:http_error, status, response}}` when the store answered (a
  404 for a missing key or bucket), or `{:error, transport_error}` when it
  could not be reached; `exists?/1` collapses both to `false`. The shapes
  are pinned against a real store in the `integration` CI job
  (`Cake.Books.Adapters.S3IntegrationTest`; CLAUDE.md "Integration tests").

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
