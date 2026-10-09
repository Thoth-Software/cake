defmodule Cake.Books.ZipExtractorPropertyTest do
  @moduledoc """
  Property tests for `Cake.Books.ZipExtractor.extract_pdfs/1`.

  A round trip through `:zip.create/3`: for any generated archive, the
  extracted pairs are exactly the entries the module's own filter admits,
  stated here as a one-line model (not under the macOS resource-fork prefix,
  not a directory, named `.pdf` in any case), with each entry's bytes intact.
  Example tests live in `zip_extractor_test.exs`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cake.Books.ZipExtractor

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  defp segment, do: string(:alphanumeric, min_length: 1, max_length: 8)

  defp extension, do: member_of([".pdf", ".PDF", ".Pdf", ".pdF", ".txt", ".png", ".pdf.bak", ""])

  # A file entry: one to three path segments, an optional resource-fork
  # prefix, and an extension drawn to land on both sides of the filter.
  defp file_entry do
    gen all(
          segments <- list_of(segment(), min_length: 1, max_length: 3),
          fork? <- boolean(),
          ext <- extension(),
          content <- binary(min_length: 1)
        ) do
      prefix = if fork?, do: "__MACOSX/", else: ""
      {prefix <> Enum.join(segments, "/") <> ext, content}
    end
  end

  # A directory entry: a trailing slash and no bytes, as archivers write them.
  defp dir_entry do
    gen all(segments <- list_of(segment(), min_length: 1, max_length: 2)) do
      {Enum.join(segments, "/") <> "/", ""}
    end
  end

  # Names are unique so the model is a set, not a multiset: what the
  # extractor does with two entries of the same name is the archiver's
  # business, not this module's contract.
  defp archive_entries do
    uniq_list_of(frequency([{4, file_entry()}, {1, dir_entry()}]),
      uniq_fun: &elem(&1, 0),
      max_length: 8
    )
  end

  defp zip!(entries) do
    charlist_entries =
      Enum.map(entries, fn {name, content} -> {String.to_charlist(name), content} end)

    {:ok, {_name, binary}} = :zip.create(~c"archive.zip", charlist_entries, [:memory])
    binary
  end

  # The contract, stated independently of the implementation.
  defp admitted?({name, _content}) do
    not String.starts_with?(name, "__MACOSX/") and
      not String.ends_with?(name, "/") and
      String.ends_with?(String.downcase(name), ".pdf")
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "extracts exactly the non-fork, non-directory .pdf entries, bytes intact" do
    check all(entries <- archive_entries()) do
      assert {:ok, pdfs} = entries |> zip!() |> ZipExtractor.extract_pdfs()

      assert Enum.sort(pdfs) == entries |> Enum.filter(&admitted?/1) |> Enum.sort()
    end
  end

  property "every extracted name is a string, never a charlist" do
    check all(entries <- archive_entries()) do
      {:ok, pdfs} = entries |> zip!() |> ZipExtractor.extract_pdfs()

      assert Enum.all?(pdfs, fn {name, content} -> is_binary(name) and is_binary(content) end)
    end
  end

  property "bytes that are not a ZIP archive yield an error tuple, never a raise" do
    check all(bytes <- binary(), not String.starts_with?(bytes, "PK")) do
      assert {:error, _reason} = ZipExtractor.extract_pdfs(bytes)
    end
  end
end
