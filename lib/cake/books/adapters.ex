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

  @doc "Reads the binary stored under `key`."
  @callback read(key()) :: {:ok, binary()} | {:error, adapter_error()}

  @doc "Writes `binary` under `key`, overwriting any existing object."
  @callback write(key(), binary()) :: :ok | {:error, adapter_error()}

  @doc "Whether an object exists under `key`."
  @callback exists?(key()) :: boolean()

  @doc "Deletes the object stored under `key`."
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

  @doc """
  Whether `key` may be handed to an adapter.

  Adapters resolve keys under a root (`Disk` joins them onto
  `:book_storage_root`), so a key must never be able to climb out of it: any
  `..` path segment is refused, as are empty, blank, NUL-bearing, and
  non-binary keys. A leading `/` is allowed — `Path.join/2` keeps it under
  the root, and legacy rows carry path-shaped keys. Request-facing code
  checks this before touching storage; `Disk` checks it again itself.
  """
  @spec valid_key?(term()) :: boolean()
  def valid_key?(key) when is_binary(key) do
    String.trim(key) != "" and not String.contains?(key, <<0>>) and
      ".." not in Path.split(key)
  end

  def valid_key?(_key), do: false
end
