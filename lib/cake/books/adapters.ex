defmodule Cake.Books.Adapters do
  @moduledoc """
  Behaviour for raw binary storage of book files.

  Adapters handle reading and writing source binaries (PDFs, etc.) to a
  storage backend. Structured data (ParsedBook records, Chunks) remains in
  Postgres via `Cake.Books.Persistence` — this behaviour is strictly for
  the raw file I/O.

  Currently reads entire files into memory. Streaming may be needed for
  very large documents in the future.

  ## Key scheme

  Keys follow the pattern `cake-documents/<tenant>/<gds>/<unique-id>`.
  For books, the unique ID is `<title>_<file_hash>` to aid human readability
  when browsing the storage backend directly.
  """

  @type key :: String.t()

  @typedoc """
  Error reasons returned by adapter implementations.

  Disk returns `t:File.posix/0` atoms. S3 passes through opaque ExAws
  errors — `ExAws.request/1` specs `{:error, term()}`, so the S3
  contribution is `term()` until ExAws publishes a concrete error type.
  The union collapses to `term()` for dialyzer today, but enumerating
  `File.posix()` explicitly documents the Disk contract and will become
  enforceable once ExAws narrows its spec.
  """
  @type adapter_error :: File.posix() | term()

  @callback read(key()) :: {:ok, binary()} | {:error, adapter_error()}
  @callback write(key(), binary()) :: :ok | {:error, adapter_error()}
  @callback exists?(key()) :: boolean()
  @callback delete(key()) :: :ok | {:error, adapter_error()}

  @spec adapter() :: module()
  def adapter do
    Application.get_env(:cake, :book_storage_adapter, Cake.Books.Adapters.Disk)
  end

  @spec tenant() :: String.t()
  def tenant do
    Application.get_env(:cake, :book_storage_tenant, "default")
  end

  @spec build_key(String.t(), String.t(), String.t()) :: key()
  def build_key(tenant \\ tenant(), gds, unique_id) do
    "cake-documents/#{tenant}/#{gds}/#{unique_id}"
  end
end
