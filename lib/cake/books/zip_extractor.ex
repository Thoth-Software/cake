defmodule Cake.Books.ZipExtractor do
  @moduledoc """
  Extracts PDF files from ZIP archives, with a bound on how far an archive
  may expand in memory.

  An upload's size limit bounds the compressed bytes only; a deflate ratio
  near 1000:1 lets a small archive expand to many gigabytes. So nothing is
  inflated until the archive's central directory has been read with
  `:zip.list_dir/1` and checked:

    * the archive holds at most `:max_entries` entries, PDF or not
      (`config :cake, :max_zip_entries`);
    * the uncompressed sizes the PDF entries declare sum to at most
      `:max_expanded_bytes` (`config :cake, :max_zip_expanded_bytes`).

  Only the PDF entries are then inflated, by this module rather than
  `:zip.unzip/2` (which trusts the compressed size and inflates however
  much output that yields): each entry is inflated with
  `:zlib.safeInflate/2` and abandoned the moment its output passes the
  size it declared, so an archive that understates its sizes in the
  central directory is rejected too. Each entry must inflate to exactly
  its declared size and match its CRC-32. Stored and deflated entries are
  supported, including the streamed layout (CRC and sizes in a trailing
  data descriptor) that macOS Archive Utility writes; macOS resource-fork
  and directory entries are skipped.
  """

  import Bitwise

  require Record

  Record.defrecordp(:zip_file, Record.extract(:zip_file, from_lib: "stdlib/include/zip.hrl"))
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @default_max_expanded_bytes 268_435_456
  @default_max_entries 10_000

  @local_header_signature 0x04034B50
  @local_header_size 30
  @data_descriptor_signature 0x08074B50
  @encrypted_flag 0x0001
  @data_descriptor_flag 0x0008
  @stored 0
  @deflated 8
  @raw_deflate_window_bits -15

  @typedoc """
  Overrides for the limits `extract_pdfs/2` otherwise reads from the
  application environment.
  """
  @type option :: {:max_expanded_bytes, non_neg_integer()} | {:max_entries, non_neg_integer()}

  @typedoc """
  Why an entry could not be extracted; reported as `{reason, entry_name}`.
  """
  @type entry_error ::
          :bad_local_header
          | :encrypted
          | :truncated
          | :unsupported_compression
          | :corrupt_entry
          | :size_mismatch
          | :bad_crc

  @typep local_header :: %{
           flags: non_neg_integer(),
           method: non_neg_integer(),
           crc: non_neg_integer(),
           data_start: non_neg_integer()
         }

  @typedoc "Why `extract_pdfs/2` rejected an archive."
  @type error ::
          {:too_large, declared_bytes :: non_neg_integer(), max_bytes :: non_neg_integer()}
          | {:too_many_entries, count :: non_neg_integer(), max :: non_neg_integer()}
          | {entry_error(), entry_name :: String.t()}
          | term()

  @doc """
  Extracts every PDF entry from a ZIP binary in memory, returning
  `{filename, binary}` pairs in archive order. macOS resource-fork and
  directory entries are skipped.

  Returns `{:error, {:too_many_entries, count, max}}` or
  `{:error, {:too_large, declared_bytes, max_bytes}}` before inflating
  anything when the archive breaks a limit, and
  `{:error, {reason, entry_name}}` (see `t:entry_error/0`) when an entry
  cannot be extracted — including one that inflates past its declared
  size. Any other error is `:zip.list_dir/1`'s, for a binary that is not
  a ZIP archive.

  The limits come from `config :cake, :max_zip_expanded_bytes` and
  `:max_zip_entries`; `opts` overrides them per call.
  """
  @spec extract_pdfs(binary(), [option()]) ::
          {:ok, [{String.t(), binary()}]} | {:error, error()}
  def extract_pdfs(zip_binary, opts \\ []) when is_binary(zip_binary) and is_list(opts) do
    max_bytes =
      Keyword.get_lazy(opts, :max_expanded_bytes, fn ->
        Application.get_env(:cake, :max_zip_expanded_bytes, @default_max_expanded_bytes)
      end)

    max_entries =
      Keyword.get_lazy(opts, :max_entries, fn ->
        Application.get_env(:cake, :max_zip_entries, @default_max_entries)
      end)

    with {:ok, listing} <- :zip.list_dir(zip_binary),
         entries = for(zip_file() = entry <- listing, do: entry),
         :ok <- check_entry_count(entries, max_entries),
         pdf_entries = Enum.filter(entries, &pdf_file?(zip_file(&1, :name))),
         :ok <- check_declared_size(pdf_entries, max_bytes) do
      extract_entries(zip_binary, pdf_entries)
    end
  end

  @spec check_entry_count(list(), non_neg_integer()) ::
          :ok | {:error, {:too_many_entries, non_neg_integer(), non_neg_integer()}}
  defp check_entry_count(entries, max_entries) do
    case length(entries) do
      count when count > max_entries -> {:error, {:too_many_entries, count, max_entries}}
      _count -> :ok
    end
  end

  @spec check_declared_size(list(), non_neg_integer()) ::
          :ok | {:error, {:too_large, non_neg_integer(), non_neg_integer()}}
  defp check_declared_size(pdf_entries, max_bytes) do
    case pdf_entries |> Enum.map(&declared_size/1) |> Enum.sum() do
      total when total > max_bytes -> {:error, {:too_large, total, max_bytes}}
      _total -> :ok
    end
  end

  @spec extract_entries(binary(), list()) ::
          {:ok, [{String.t(), binary()}]} | {:error, {entry_error(), String.t()}}
  defp extract_entries(zip_binary, pdf_entries) do
    result =
      Enum.reduce_while(pdf_entries, {:ok, []}, fn entry, {:ok, acc} ->
        name = entry |> zip_file(:name) |> List.to_string()

        case extract_entry(zip_binary, entry) do
          {:ok, content} -> {:cont, {:ok, [{name, content} | acc]}}
          {:error, reason} -> {:halt, {:error, {reason, name}}}
        end
      end)

    with {:ok, pdfs} <- result, do: {:ok, Enum.reverse(pdfs)}
  end

  @spec extract_entry(binary(), tuple()) :: {:ok, binary()} | {:error, entry_error()}
  defp extract_entry(zip_binary, entry) do
    comp_size = zip_file(entry, :comp_size)

    with {:ok, header} <- read_local_header(zip_binary, zip_file(entry, :offset)),
         :ok <- check_not_encrypted(header.flags),
         {:ok, data} <- slice(zip_binary, header.data_start, comp_size),
         {:ok, content} <- decompress(header.method, data, declared_size(entry)),
         {:ok, crc} <- expected_crc(zip_binary, header, header.data_start + comp_size) do
      if :erlang.crc32(content) == crc, do: {:ok, content}, else: {:error, :bad_crc}
    end
  end

  @spec read_local_header(binary(), non_neg_integer()) ::
          {:ok, local_header()} | {:error, :bad_local_header}
  defp read_local_header(zip_binary, offset) do
    case zip_binary do
      <<_::binary-size(^offset), @local_header_signature::little-32, _version::little-16,
        flags::little-16, method::little-16, _mod_time::little-16, _mod_date::little-16,
        crc::little-32, _comp_size::little-32, _uncomp_size::little-32, name_length::little-16,
        extra_length::little-16, _::binary>> ->
        data_start = offset + @local_header_size + name_length + extra_length
        {:ok, %{flags: flags, method: method, crc: crc, data_start: data_start}}

      _ ->
        {:error, :bad_local_header}
    end
  end

  @spec check_not_encrypted(non_neg_integer()) :: :ok | {:error, :encrypted}
  defp check_not_encrypted(flags) when (flags &&& @encrypted_flag) != 0, do: {:error, :encrypted}
  defp check_not_encrypted(_flags), do: :ok

  @spec slice(binary(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, :truncated}
  defp slice(binary, start, length) when start + length <= byte_size(binary),
    do: {:ok, binary_part(binary, start, length)}

  defp slice(_binary, _start, _length), do: {:error, :truncated}

  @spec decompress(non_neg_integer(), binary(), non_neg_integer()) ::
          {:ok, binary()}
          | {:error, :unsupported_compression | :corrupt_entry | :size_mismatch}
  defp decompress(@stored, data, declared) when byte_size(data) == declared, do: {:ok, data}
  defp decompress(@stored, _data, _declared), do: {:error, :size_mismatch}

  defp decompress(@deflated, data, declared) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, @raw_deflate_window_bits)
      inflate_bounded(z, :zlib.safeInflate(z, data), declared, [], 0)
    rescue
      ErlangError -> {:error, :corrupt_entry}
    after
      :zlib.close(z)
    end
  end

  defp decompress(_method, _data, _declared), do: {:error, :unsupported_compression}

  # Pulls output from `safeInflate/2` one bounded chunk at a time, so at
  # most one chunk past the declared size is ever held before giving up.
  @spec inflate_bounded(
          :zlib.zstream(),
          {:continue | :finished, iodata()},
          non_neg_integer(),
          [iodata()],
          non_neg_integer()
        ) :: {:ok, binary()} | {:error, :corrupt_entry | :size_mismatch}
  defp inflate_bounded(z, {status, output}, declared, acc, size) do
    output_size = IO.iodata_length(output)
    size = size + output_size
    acc = [acc | output]

    cond do
      size > declared -> {:error, :size_mismatch}
      status == :finished and size == declared -> {:ok, IO.iodata_to_binary(acc)}
      status == :finished -> {:error, :size_mismatch}
      # Input exhausted, no output, stream unfinished: truncated deflate data.
      output_size == 0 -> {:error, :corrupt_entry}
      true -> inflate_bounded(z, :zlib.safeInflate(z, []), declared, acc, size)
    end
  end

  # With general-purpose flag bit 3 set, the local header's CRC is zero
  # and the real one follows the entry's data in a data descriptor, whose
  # signature is optional.
  @spec expected_crc(binary(), local_header(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :truncated}
  defp expected_crc(zip_binary, %{flags: flags}, data_end)
       when (flags &&& @data_descriptor_flag) != 0 do
    case zip_binary do
      <<_::binary-size(^data_end), @data_descriptor_signature::little-32, crc::little-32,
        _::binary>> ->
        {:ok, crc}

      <<_::binary-size(^data_end), crc::little-32, _::binary>> ->
        {:ok, crc}

      _ ->
        {:error, :truncated}
    end
  end

  defp expected_crc(_zip_binary, %{crc: crc}, _data_end), do: {:ok, crc}

  @spec declared_size(tuple()) :: non_neg_integer()
  defp declared_size(entry), do: entry |> zip_file(:info) |> file_info(:size)

  @spec pdf_file?(charlist()) :: boolean()
  defp pdf_file?(filename) do
    name = List.to_string(filename)

    not String.starts_with?(name, "__MACOSX/") and
      not String.ends_with?(name, "/") and
      String.ends_with?(String.downcase(name), ".pdf")
  end
end
