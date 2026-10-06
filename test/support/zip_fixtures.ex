defmodule Cake.ZipFixtures do
  @moduledoc """
  ZIP archives for the `Cake.Books.ZipExtractor` and `CakeWeb.UploadLive`
  tests: well-formed archives from `:zip.create/3`, archives in the
  streamed layout (sizes and CRC in a trailing data descriptor) that macOS
  Archive Utility writes, and forgeries that misstate an entry's declared
  size, checksum or compression method.
  """

  import Bitwise

  @local_header_signature 0x04034B50
  @central_header_signature 0x02014B50
  @end_of_central_dir_signature 0x06054B50
  @data_descriptor_signature 0x08074B50
  @zip64_end_of_central_dir_signature 0x06064B50
  @zip64_end_of_central_dir_locator_signature 0x07064B50
  @zip64_extra_id 0x0001
  @zip64_marker_16 0xFFFF
  @zip64_marker_32 0xFFFFFFFF
  @data_descriptor_flag 0x0008
  @deflated 8
  # 2020-01-01, in MS-DOS date format.
  @dos_date (2020 - 1980) <<< 9 ||| 1 <<< 5 ||| 1

  @doc """
  Builds an archive of `{name, content}` entries with `:zip.create/3`.
  `opts` are passed through (e.g. `compress: []` to store every entry).
  """
  @spec zip_binary([{String.t(), binary()}], [:zip.create_option()]) :: binary()
  def zip_binary(entries, opts \\ []) when is_list(entries) do
    charlist_entries =
      Enum.map(entries, fn {name, content} -> {String.to_charlist(name), content} end)

    {:ok, {_name, binary}} = :zip.create(~c"test.zip", charlist_entries, [:memory | opts])
    binary
  end

  @doc """
  Builds a deflated archive in the streamed layout: each local header
  sets general-purpose flag bit 3 and zeroes its CRC and sizes, and a
  data descriptor carrying them follows the entry's data.

  With `zip64: true`, every central-directory header marks its sizes and
  offset `0xFFFFFFFF` and carries them in a ZIP64 extra field, and the
  end of the archive is a ZIP64 end record and locator ahead of a classic
  end record whose count and offset are marked likewise.
  """
  @spec streamed_zip_binary([{String.t(), binary()}], zip64: boolean()) :: binary()
  def streamed_zip_binary(entries, opts \\ []) when is_list(entries) do
    zip64? = Keyword.get(opts, :zip64, false)

    {locals, centrals, cd_offset} = streamed_entries(entries, zip64?)
    central_dir = IO.iodata_to_binary(centrals)
    end_records = end_records(length(entries), byte_size(central_dir), cd_offset, zip64?)

    IO.iodata_to_binary([locals, central_dir, end_records])
  end

  @spec streamed_entries([{String.t(), binary()}], boolean()) ::
          {[binary()], [binary()], non_neg_integer()}
  defp streamed_entries(entries, zip64?) do
    {locals, centrals, cd_offset} =
      Enum.reduce(entries, {[], [], 0}, fn {name, content}, {locals, centrals, offset} ->
        {local, central} = streamed_entry(name, content, offset, zip64?)
        {[local | locals], [central | centrals], offset + byte_size(local)}
      end)

    {Enum.reverse(locals), Enum.reverse(centrals), cd_offset}
  end

  @spec streamed_entry(binary(), binary(), non_neg_integer(), boolean()) :: {binary(), binary()}
  defp streamed_entry(name, content, offset, zip64?) do
    compressed = :zlib.zip(content)
    crc = :erlang.crc32(content)

    {streamed_local_entry(name, content, compressed, crc),
     central_header(name, crc, byte_size(compressed), byte_size(content), offset, zip64?)}
  end

  @spec streamed_local_entry(binary(), binary(), binary(), non_neg_integer()) :: binary()
  defp streamed_local_entry(name, content, compressed, crc) do
    <<@local_header_signature::little-32, 20::little-16, @data_descriptor_flag::little-16,
      @deflated::little-16, 0::little-16, @dos_date::little-16, 0::little-32, 0::little-32,
      0::little-32, byte_size(name)::little-16, 0::little-16, name::binary, compressed::binary,
      @data_descriptor_signature::little-32, crc::little-32, byte_size(compressed)::little-32,
      byte_size(content)::little-32>>
  end

  @spec central_header(
          binary(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          boolean()
        ) :: binary()
  defp central_header(name, crc, comp_size, uncomp_size, offset, zip64?) do
    {comp_field, uncomp_field, offset_field, extra} =
      if zip64? do
        {@zip64_marker_32, @zip64_marker_32, @zip64_marker_32,
         <<@zip64_extra_id::little-16, 24::little-16, uncomp_size::little-64,
           comp_size::little-64, offset::little-64>>}
      else
        {comp_size, uncomp_size, offset, <<>>}
      end

    <<@central_header_signature::little-32, 45::little-16, 45::little-16,
      @data_descriptor_flag::little-16, @deflated::little-16, 0::little-16, @dos_date::little-16,
      crc::little-32, comp_field::little-32, uncomp_field::little-32, byte_size(name)::little-16,
      byte_size(extra)::little-16, 0::little-16, 0::little-16, 0::little-16, 0::little-32,
      offset_field::little-32, name::binary, extra::binary>>
  end

  @spec end_records(non_neg_integer(), non_neg_integer(), non_neg_integer(), boolean()) ::
          binary()
  defp end_records(count, cd_size, cd_offset, false) do
    <<@end_of_central_dir_signature::little-32, 0::little-16, 0::little-16, count::little-16,
      count::little-16, cd_size::little-32, cd_offset::little-32, 0::little-16>>
  end

  defp end_records(count, cd_size, cd_offset, true) do
    zip64_record_offset = cd_offset + cd_size

    zip64_record =
      <<@zip64_end_of_central_dir_signature::little-32, 44::little-64, 45::little-16,
        45::little-16, 0::little-32, 0::little-32, count::little-64, count::little-64,
        cd_size::little-64, cd_offset::little-64>>

    locator =
      <<@zip64_end_of_central_dir_locator_signature::little-32, 0::little-32,
        zip64_record_offset::little-64, 1::little-32>>

    classic =
      <<@end_of_central_dir_signature::little-32, 0::little-16, 0::little-16,
        @zip64_marker_16::little-16, @zip64_marker_16::little-16, @zip64_marker_32::little-32,
        @zip64_marker_32::little-32, 0::little-16>>

    zip64_record <> locator <> classic
  end

  @doc """
  Rewrites the uncompressed size the central directory declares for
  `name`, leaving the entry's data untouched — the shape of an archive
  that lies about how far it expands.
  """
  @spec forge_declared_size(binary(), String.t(), non_neg_integer()) :: binary()
  def forge_declared_size(zip, name, size) do
    patch(zip, central_header_position(zip, name) + 24, <<size::little-32>>)
  end

  @doc "Rewrites the CRC-32 the central directory records for `name`."
  @spec forge_crc(binary(), String.t(), non_neg_integer()) :: binary()
  def forge_crc(zip, name, crc) do
    patch(zip, central_header_position(zip, name) + 16, <<crc::little-32>>)
  end

  @doc "Rewrites the compression method the central directory records for `name`."
  @spec forge_compression_method(binary(), String.t(), non_neg_integer()) :: binary()
  def forge_compression_method(zip, name, method) do
    patch(zip, central_header_position(zip, name) + 10, <<method::little-16>>)
  end

  @doc """
  Zeroes the signature of the first central-directory header, so any
  reader that walks the central directory fails on its first entry.
  """
  @spec corrupt_central_directory(binary()) :: binary()
  def corrupt_central_directory(zip) do
    {position, _length} = :binary.match(zip, <<@central_header_signature::little-32>>)
    patch(zip, position, <<0::32>>)
  end

  @spec central_header_position(binary(), String.t()) :: non_neg_integer()
  defp central_header_position(zip, name) do
    zip
    |> :binary.matches(<<@central_header_signature::little-32>>)
    |> Enum.find_value(fn {position, _length} ->
      <<_::binary-size(^position + 28), name_length::little-16, _::binary>> = zip

      if binary_part(zip, position + 46, name_length) == name, do: position
    end) || raise ArgumentError, "no central directory entry named #{inspect(name)}"
  end

  @spec patch(binary(), non_neg_integer(), binary()) :: binary()
  defp patch(binary, position, replacement) do
    <<before::binary-size(^position), _::binary-size(byte_size(^replacement)), rest::binary>> =
      binary

    <<before::binary, replacement::binary, rest::binary>>
  end
end
