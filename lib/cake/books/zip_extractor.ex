defmodule Cake.Books.ZipExtractor do
  @moduledoc """
  Extracts PDF files from ZIP archives, with a bound on how far an archive
  may expand in memory.

  An upload's size limit bounds the compressed bytes only; a deflate ratio
  near 1000:1 lets a small archive expand to many gigabytes, and an archive
  of many tiny entries costs memory just to list. So the archive is read in
  three bounded steps:

    1. The end-of-central-directory record (ZIP64 included) gives the entry
       count, and an archive with more than `:max_entries` entries, PDF or
       not, is rejected before any entry is read
       (`config :cake, :max_zip_entries`).
    2. The central directory is parsed here, not with `:zip.list_dir/1`
       (which turns every name into a charlist, costing kilobytes of heap
       per entry): names stay sub-binaries of the upload. An archive whose
       PDF entries declare more than `:max_expanded_bytes` uncompressed in
       total is rejected before anything is inflated
       (`config :cake, :max_zip_expanded_bytes`).
    3. Only the PDF entries are inflated, by this module rather than
       `:zip.unzip/2` (which trusts the compressed size and inflates
       however much output that yields): each one with
       `:zlib.safeInflate/2`, abandoned the moment its output passes the
       size the central directory declares for it, so an archive that
       understates its sizes is rejected too. Each entry must inflate to
       exactly its declared size and match the central directory's CRC-32.

  Stored and deflated entries are supported, including the streamed
  layout (data descriptors) that macOS Archive Utility writes; macOS
  resource-fork and directory entries are skipped. Encrypted and
  multi-disk archives are not supported.
  """

  import Bitwise

  @default_max_expanded_bytes 268_435_456
  @default_max_entries 10_000

  @eocd_signature 0x06054B50
  @eocd_size 22
  @max_comment_size 0xFFFF
  @zip64_eocd_locator_signature 0x07064B50
  @zip64_eocd_locator_size 20
  @zip64_eocd_signature 0x06064B50
  @central_header_signature 0x02014B50
  @central_header_size 46
  @local_header_signature 0x04034B50
  @local_header_size 30
  @zip64_extra_id 0x0001
  @zip64_marker_16 0xFFFF
  @zip64_marker_32 0xFFFFFFFF
  @encrypted_flag 0x0001
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

  @typedoc "Why `extract_pdfs/2` rejected an archive."
  @type error ::
          :not_a_zip
          | :bad_central_directory
          | :multiple_disks_not_supported
          | {:too_many_entries, count :: non_neg_integer(), max :: non_neg_integer()}
          | {:too_large, declared_bytes :: non_neg_integer(), max_bytes :: non_neg_integer()}
          | {entry_error(), entry_name :: String.t()}

  @typep central_entry :: %{
           name: String.t(),
           flags: non_neg_integer(),
           method: non_neg_integer(),
           crc: non_neg_integer(),
           comp_size: non_neg_integer(),
           uncomp_size: non_neg_integer(),
           offset: non_neg_integer()
         }

  @doc """
  Extracts every PDF entry from a ZIP binary in memory, returning
  `{filename, binary}` pairs in archive order. macOS resource-fork and
  directory entries are skipped.

  Before inflating anything, returns `{:error, :not_a_zip}`,
  `{:error, :bad_central_directory}` or
  `{:error, :multiple_disks_not_supported}` for an archive it cannot read,
  and `{:error, {:too_many_entries, count, max}}` or
  `{:error, {:too_large, declared_bytes, max_bytes}}` for one that breaks
  a limit. Returns `{:error, {reason, entry_name}}` (see
  `t:entry_error/0`) when an entry cannot be extracted — including one
  that inflates past its declared size.

  The limits come from `config :cake, :max_zip_expanded_bytes` and
  `:max_zip_entries`; `opts` overrides them per call.
  """
  @spec extract_pdfs(binary(), [option()]) ::
          {:ok, [{String.t(), binary()}]} | {:error, error()}
  def extract_pdfs(zip_binary, opts \\ []) when is_binary(zip_binary) and is_list(opts) do
    max_bytes =
      limit(opts, :max_expanded_bytes, :max_zip_expanded_bytes, @default_max_expanded_bytes)

    max_entries = limit(opts, :max_entries, :max_zip_entries, @default_max_entries)

    with {:ok, eocd} <- find_end_of_central_dir(zip_binary),
         :ok <- check_entry_count(eocd.entries, max_entries),
         {:ok, entries} <- read_central_dir(zip_binary, eocd.cd_offset, eocd.entries, []),
         pdf_entries = Enum.filter(entries, &pdf_file?(&1.name)),
         :ok <- check_declared_size(pdf_entries, max_bytes) do
      extract_entries(zip_binary, pdf_entries)
    end
  end

  @spec limit(keyword(), atom(), atom(), non_neg_integer()) :: non_neg_integer()
  defp limit(opts, opt_key, config_key, default) do
    Keyword.get_lazy(opts, opt_key, fn -> Application.get_env(:cake, config_key, default) end)
  end

  # The record sits in the last 22 bytes plus an archive comment of up to
  # 64 KB. The comment may itself contain the signature, or a whole
  # record, so candidates are tried right to left: one counts only if its
  # comment length ends it exactly at the end of the binary and its central
  # directory ends exactly where it (or its ZIP64 record) starts. If none
  # parses, the rightmost end-aligned candidate's error is returned.
  @spec find_end_of_central_dir(binary()) ::
          {:ok, %{entries: non_neg_integer(), cd_offset: non_neg_integer()}}
          | {:error, :not_a_zip | :bad_central_directory | :multiple_disks_not_supported}
  defp find_end_of_central_dir(zip_binary) do
    size = byte_size(zip_binary)
    window_start = max(size - @eocd_size - @max_comment_size, 0)
    window = binary_part(zip_binary, window_start, size - window_start)

    results =
      window
      |> :binary.matches(<<@eocd_signature::little-32>>)
      |> Enum.map(fn {position, _length} -> window_start + position end)
      |> Enum.reverse()
      |> Enum.filter(&end_of_central_dir_at?(zip_binary, &1))
      |> Enum.map(&parse_end_of_central_dir(zip_binary, &1))

    Enum.find(results, &match?({:ok, _}, &1)) || List.first(results, {:error, :not_a_zip})
  end

  @spec end_of_central_dir_at?(binary(), non_neg_integer()) :: boolean()
  defp end_of_central_dir_at?(zip_binary, position) do
    case zip_binary do
      <<_::binary-size(^position), _::binary-size(20), comment_length::little-16, _::binary>> ->
        position + @eocd_size + comment_length == byte_size(zip_binary)

      _ ->
        false
    end
  end

  @spec parse_end_of_central_dir(binary(), non_neg_integer()) ::
          {:ok, %{entries: non_neg_integer(), cd_offset: non_neg_integer()}}
          | {:error, :not_a_zip | :bad_central_directory | :multiple_disks_not_supported}
  defp parse_end_of_central_dir(zip_binary, position) do
    case zip_binary do
      <<_::binary-size(^position), @eocd_signature::little-32, disk::little-16,
        cd_disk::little-16, _disk_entries::little-16, entries::little-16, cd_size::little-32,
        cd_offset::little-32, _::binary>> ->
        cond do
          @zip64_marker_16 in [disk, cd_disk, entries] or
              @zip64_marker_32 in [cd_size, cd_offset] ->
            parse_zip64_eocd(zip_binary, position)

          disk != 0 or cd_disk != 0 ->
            {:error, :multiple_disks_not_supported}

          cd_offset + cd_size != position ->
            {:error, :bad_central_directory}

          true ->
            {:ok, %{entries: entries, cd_offset: cd_offset}}
        end

      _ ->
        {:error, :not_a_zip}
    end
  end

  # A ZIP64 end record is found through the locator just before the
  # classic record.
  @spec parse_zip64_eocd(binary(), non_neg_integer()) ::
          {:ok, %{entries: non_neg_integer(), cd_offset: non_neg_integer()}}
          | {:error, :bad_central_directory | :multiple_disks_not_supported}
  defp parse_zip64_eocd(zip_binary, eocd_position)
       when eocd_position >= @zip64_eocd_locator_size do
    locator_position = eocd_position - @zip64_eocd_locator_size

    with <<_::binary-size(^locator_position), @zip64_eocd_locator_signature::little-32,
           record_disk::little-32, record_position::little-64, total_disks::little-32,
           _::binary>> <- zip_binary,
         <<_::binary-size(^record_position), @zip64_eocd_signature::little-32,
           _record_size::little-64, _made_by::little-16, _needed::little-16, disk::little-32,
           cd_disk::little-32, _disk_entries::little-64, entries::little-64, cd_size::little-64,
           cd_offset::little-64, _::binary>> <- zip_binary do
      cond do
        record_disk != 0 or total_disks > 1 or disk != 0 or cd_disk != 0 ->
          {:error, :multiple_disks_not_supported}

        cd_offset + cd_size != record_position ->
          {:error, :bad_central_directory}

        true ->
          {:ok, %{entries: entries, cd_offset: cd_offset}}
      end
    else
      _ -> {:error, :bad_central_directory}
    end
  end

  defp parse_zip64_eocd(_zip_binary, _eocd_position), do: {:error, :bad_central_directory}

  @spec check_entry_count(non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, {:too_many_entries, non_neg_integer(), non_neg_integer()}}
  defp check_entry_count(count, max_entries) when count > max_entries,
    do: {:error, {:too_many_entries, count, max_entries}}

  defp check_entry_count(_count, _max_entries), do: :ok

  # Runs only after check_entry_count/2, so `remaining` is bounded.
  @spec read_central_dir(binary(), non_neg_integer(), non_neg_integer(), [central_entry()]) ::
          {:ok, [central_entry()]} | {:error, :bad_central_directory}
  defp read_central_dir(_zip_binary, _position, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp read_central_dir(zip_binary, position, remaining, acc) do
    case zip_binary do
      <<_::binary-size(^position), @central_header_signature::little-32, _made_by::little-16,
        _needed::little-16, flags::little-16, method::little-16, _mod_time::little-16,
        _mod_date::little-16, crc::little-32, comp_size::little-32, uncomp_size::little-32,
        name_length::little-16, extra_length::little-16, comment_length::little-16,
        _disk::little-16, _internal_attrs::little-16, _external_attrs::little-32,
        offset::little-32, name::binary-size(name_length), extra::binary-size(extra_length),
        _comment::binary-size(comment_length), _::binary>> ->
        entry = %{
          name: decode_name(name),
          flags: flags,
          method: method,
          crc: crc,
          comp_size: comp_size,
          uncomp_size: uncomp_size,
          offset: offset
        }

        next = position + @central_header_size + name_length + extra_length + comment_length

        with {:ok, entry} <- apply_zip64_extra(entry, extra) do
          read_central_dir(zip_binary, next, remaining - 1, [entry | acc])
        end

      _ ->
        {:error, :bad_central_directory}
    end
  end

  # Names flagged UTF-8 (and plain ASCII) pass through; anything else is
  # read as Latin-1, so a name is always a valid string.
  @spec decode_name(binary()) :: String.t()
  defp decode_name(name) do
    if String.valid?(name), do: name, else: :unicode.characters_to_binary(name, :latin1)
  end

  # A size or offset too large for its 32-bit field is 0xFFFFFFFF there,
  # with the real value in the ZIP64 extra field, in this order.
  @spec apply_zip64_extra(central_entry(), binary()) ::
          {:ok, central_entry()} | {:error, :bad_central_directory}
  defp apply_zip64_extra(entry, extra) do
    case Enum.filter([:uncomp_size, :comp_size, :offset], &(entry[&1] == @zip64_marker_32)) do
      [] ->
        {:ok, entry}

      fields ->
        value_bytes = length(fields) * 8

        with {:ok, data} <- find_extra_block(extra, @zip64_extra_id),
             <<values::binary-size(^value_bytes), _::binary>> <- data do
          {:ok,
           Map.merge(entry, Map.new(Enum.zip(fields, for(<<v::little-64 <- values>>, do: v))))}
        else
          _ -> {:error, :bad_central_directory}
        end
    end
  end

  @spec find_extra_block(binary(), non_neg_integer()) :: {:ok, binary()} | :error
  defp find_extra_block(
         <<id::little-16, size::little-16, data::binary-size(size), _::binary>>,
         id
       ),
       do: {:ok, data}

  defp find_extra_block(
         <<_id::little-16, size::little-16, _::binary-size(size), rest::binary>>,
         id
       ),
       do: find_extra_block(rest, id)

  defp find_extra_block(_extra, _id), do: :error

  @spec check_declared_size([central_entry()], non_neg_integer()) ::
          :ok | {:error, {:too_large, non_neg_integer(), non_neg_integer()}}
  defp check_declared_size(pdf_entries, max_bytes) do
    case pdf_entries |> Enum.map(& &1.uncomp_size) |> Enum.sum() do
      total when total > max_bytes -> {:error, {:too_large, total, max_bytes}}
      _total -> :ok
    end
  end

  @spec extract_entries(binary(), [central_entry()]) ::
          {:ok, [{String.t(), binary()}]} | {:error, {entry_error(), String.t()}}
  defp extract_entries(zip_binary, pdf_entries) do
    result =
      Enum.reduce_while(pdf_entries, {:ok, []}, fn entry, {:ok, acc} ->
        case extract_entry(zip_binary, entry) do
          {:ok, content} -> {:cont, {:ok, [{entry.name, content} | acc]}}
          {:error, reason} -> {:halt, {:error, {reason, entry.name}}}
        end
      end)

    with {:ok, pdfs} <- result, do: {:ok, Enum.reverse(pdfs)}
  end

  # Sizes, method, flags and CRC all come from the central directory; the
  # local header is read only to find where the entry's data starts.
  @spec extract_entry(binary(), central_entry()) :: {:ok, binary()} | {:error, entry_error()}
  defp extract_entry(zip_binary, entry) do
    with :ok <- check_not_encrypted(entry.flags),
         {:ok, data_start} <- local_data_start(zip_binary, entry.offset),
         {:ok, data} <- slice(zip_binary, data_start, entry.comp_size),
         {:ok, content} <- decompress(entry.method, data, entry.uncomp_size) do
      if :erlang.crc32(content) == entry.crc, do: {:ok, content}, else: {:error, :bad_crc}
    end
  end

  @spec check_not_encrypted(non_neg_integer()) :: :ok | {:error, :encrypted}
  defp check_not_encrypted(flags) when (flags &&& @encrypted_flag) != 0, do: {:error, :encrypted}
  defp check_not_encrypted(_flags), do: :ok

  @spec local_data_start(binary(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :bad_local_header}
  defp local_data_start(zip_binary, offset) do
    case zip_binary do
      <<_::binary-size(^offset), @local_header_signature::little-32, _::binary-size(22),
        name_length::little-16, extra_length::little-16, _::binary>> ->
        {:ok, offset + @local_header_size + name_length + extra_length}

      _ ->
        {:error, :bad_local_header}
    end
  end

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
          iodata(),
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

  @spec pdf_file?(String.t()) :: boolean()
  defp pdf_file?(name) do
    not String.starts_with?(name, "__MACOSX/") and
      not String.ends_with?(name, "/") and
      String.ends_with?(String.downcase(name), ".pdf")
  end
end
