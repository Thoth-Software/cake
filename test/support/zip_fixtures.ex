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
  """
  @spec streamed_zip_binary([{String.t(), binary()}]) :: binary()
  def streamed_zip_binary(entries) when is_list(entries) do
    {locals, centrals, cd_offset} =
      Enum.reduce(entries, {[], [], 0}, fn {name, content}, {locals, centrals, offset} ->
        compressed = :zlib.zip(content)
        crc = :erlang.crc32(content)

        local =
          <<@local_header_signature::little-32, 20::little-16, @data_descriptor_flag::little-16,
            @deflated::little-16, 0::little-16, @dos_date::little-16, 0::little-32, 0::little-32,
            0::little-32, byte_size(name)::little-16, 0::little-16, name::binary,
            compressed::binary, @data_descriptor_signature::little-32, crc::little-32,
            byte_size(compressed)::little-32, byte_size(content)::little-32>>

        central =
          <<@central_header_signature::little-32, 20::little-16, 20::little-16,
            @data_descriptor_flag::little-16, @deflated::little-16, 0::little-16,
            @dos_date::little-16, crc::little-32, byte_size(compressed)::little-32,
            byte_size(content)::little-32, byte_size(name)::little-16, 0::little-16, 0::little-16,
            0::little-16, 0::little-16, 0::little-32, offset::little-32, name::binary>>

        {[local | locals], [central | centrals], offset + byte_size(local)}
      end)

    central_dir = centrals |> Enum.reverse() |> IO.iodata_to_binary()
    count = length(entries)

    end_of_central_dir =
      <<@end_of_central_dir_signature::little-32, 0::little-16, 0::little-16, count::little-16,
        count::little-16, byte_size(central_dir)::little-32, cd_offset::little-32, 0::little-16>>

    IO.iodata_to_binary([Enum.reverse(locals), central_dir, end_of_central_dir])
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

  @doc "Rewrites the CRC-32 in `name`'s local header."
  @spec forge_local_crc(binary(), String.t(), non_neg_integer()) :: binary()
  def forge_local_crc(zip, name, crc) do
    patch(zip, local_header_position(zip, name) + 14, <<crc::little-32>>)
  end

  @doc "Rewrites the compression method in `name`'s local header."
  @spec forge_compression_method(binary(), String.t(), non_neg_integer()) :: binary()
  def forge_compression_method(zip, name, method) do
    patch(zip, local_header_position(zip, name) + 8, <<method::little-16>>)
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

  @spec local_header_position(binary(), String.t()) :: non_neg_integer()
  defp local_header_position(zip, name) do
    position = central_header_position(zip, name)
    <<_::binary-size(^position + 42), offset::little-32, _::binary>> = zip
    offset
  end

  @spec patch(binary(), non_neg_integer(), binary()) :: binary()
  defp patch(binary, position, replacement) do
    <<before::binary-size(^position), _::binary-size(byte_size(^replacement)), rest::binary>> =
      binary

    <<before::binary, replacement::binary, rest::binary>>
  end
end
