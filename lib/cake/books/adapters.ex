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

  @callback read(key()) :: {:ok, binary()} | {:error, term()}
  @callback write(key(), binary()) :: :ok | {:error, term()}
  @callback exists?(key()) :: boolean()
  @callback delete(key()) :: :ok | {:error, term()}

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
