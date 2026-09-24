# Regenerates every fixture in this directory. Run from the repo root:
#
#     elixir test/support/fixtures/pdfs/generate.exs
#
# The script needs nothing but Elixir: it writes each PDF by hand (PDF 1.4,
# uncompressed streams, the standard Helvetica font, correct xref offsets)
# so the output is byte-for-byte deterministic and every fixture stays a few
# KB. See README.md next to this file for what each fixture pins.
defmodule Cake.PdfFixtureGenerator do
  @moduledoc false

  @dir __DIR__
  @first_page_object 4

  @doc "Writes every fixture into this directory."
  @spec run() :: :ok
  def run do
    write("multi_page.pdf", multi_page())
    write("blank_pages.pdf", blank_pages())
    write("no_title.pdf", no_title())
    write("junk_title.pdf", junk_title())
    write("skipped_page.pdf", skipped_page())
    write("truncated.pdf", truncated(multi_page()))
  end

  # A normal three-page PDF with a metadata title.
  defp multi_page do
    pdf(
      [
        text_page(["Cake Fixture Book", "Chapter one begins on the first page."]),
        text_page(["The second page continues the story.", "It has two lines of text."]),
        text_page(["The third page ends the book."])
      ],
      title: "Cake Fixture Book"
    )
  end

  # Four pages, no metadata title: pages 1 and 3 draw a rectangle and carry
  # no text at all, so a text extractor sees them as blank. Rejecting them
  # must leave the remaining chunk indices dense, and with no text on the
  # first page the title falls through to the filename.
  defp blank_pages do
    pdf([
      drawing_page(),
      text_page(["Text on page two."]),
      drawing_page(),
      text_page(["Text on page four."])
    ])
  end

  # No Info dictionary at all: the title must come from the first line of the
  # first page.
  defp no_title do
    pdf([
      text_page(["Title From The First Line", "Body text below the heading."]),
      text_page(["Second page of the untitled book."])
    ])
  end

  # A metadata title that is junk (a revision stamp, as in #86) sitting above
  # a perfectly good heading on the first page.
  defp junk_title do
    pdf(
      [
        text_page(["Sand Filter Installation Manual", "Read all instructions first."]),
        text_page(["Electrical supply requirements."])
      ],
      title: "Rev. 6/07"
    )
  end

  # Three pages whose middle page has a malformed content stream: its `Tf`
  # (set font) operator has no operands, which lopdf reports as a syntax error
  # for that page alone, so it is skipped rather than aborting the file.
  # (lopdf tolerates most other damage — unterminated strings, unbalanced
  # delimiters, binary garbage — and yields an empty page instead.)
  defp skipped_page do
    pdf(
      [
        text_page(["Before the broken page."]),
        "BT Tf (text behind a font operator with no operands) Tj ET",
        text_page(["After the broken page."])
      ],
      title: "Partially Extractable"
    )
  end

  # The first 256 bytes of a valid PDF: the header is intact but the page
  # tree, xref table and trailer are gone.
  defp truncated(valid_pdf), do: binary_part(valid_pdf, 0, 256)

  # ---------------------------------------------------------------------
  # Page builders. Each returns a content stream body; pages share one
  # Helvetica font resource (`/F1`).
  # ---------------------------------------------------------------------

  defp text_page(lines) do
    lines
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {line, index} ->
      y = 720 - index * 20
      "BT /F1 12 Tf 72 #{y} Td (#{escape(line)}) Tj ET"
    end)
  end

  defp drawing_page, do: "0.9 g 72 500 200 100 re f"

  defp escape(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("(", "\\(")
    |> String.replace(")", "\\)")
  end

  # ---------------------------------------------------------------------
  # PDF assembly. Object numbering: 1 catalog, 2 page tree, 3 font, then a
  # page dictionary and content stream per page (from @first_page_object),
  # then the optional Info dictionary last.
  # ---------------------------------------------------------------------

  defp pdf(contents, opts \\ []) do
    page_count = length(contents)
    page_objects = Enum.map(0..(page_count - 1), &(@first_page_object + &1 * 2))
    kids = Enum.map_join(page_objects, " ", &"#{&1} 0 R")

    catalog = "<< /Type /Catalog /Pages 2 0 R >>"
    pages = "<< /Type /Pages /Kids [#{kids}] /Count #{page_count} >>"

    font =
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"

    page_bodies = contents |> Enum.zip(page_objects) |> Enum.flat_map(&page_objects/1)
    {info_bodies, trailer_info} = info(opts, @first_page_object + page_count * 2)

    assemble([catalog, pages, font] ++ page_bodies ++ info_bodies, trailer_info)
  end

  # A page dictionary and its content stream, as consecutive objects.
  defp page_objects({content, page_object}) do
    page =
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " <>
        "/Resources << /Font << /F1 3 0 R >> >> /Contents #{page_object + 1} 0 R >>"

    stream = "<< /Length #{byte_size(content)} >>\nstream\n#{content}\nendstream"
    [page, stream]
  end

  # The Info dictionary (as object `info_object`) and its trailer entry, when
  # a title was given; nothing otherwise.
  defp info(opts, info_object) do
    case Keyword.fetch(opts, :title) do
      {:ok, title} -> {["<< /Title (#{escape(title)}) >>"], " /Info #{info_object} 0 R"}
      :error -> {[], ""}
    end
  end

  defp assemble(bodies, trailer_info) do
    header = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n"

    {body, offsets} =
      bodies
      |> Enum.with_index(1)
      |> Enum.reduce({header, []}, fn {object, number}, {acc, offsets} ->
        offset = byte_size(acc)
        {acc <> "#{number} 0 obj\n#{object}\nendobj\n", [offset | offsets]}
      end)

    xref_offset = byte_size(body)
    size = length(bodies) + 1

    entries =
      offsets
      |> Enum.reverse()
      |> Enum.map_join("", fn offset ->
        String.pad_leading(Integer.to_string(offset), 10, "0") <> " 00000 n \n"
      end)

    xref = "xref\n0 #{size}\n0000000000 65535 f \n" <> entries

    trailer =
      "trailer\n<< /Size #{size} /Root 1 0 R#{trailer_info} >>\n" <>
        "startxref\n#{xref_offset}\n%%EOF\n"

    body <> xref <> trailer
  end

  defp write(name, binary), do: File.write!(Path.join(@dir, name), binary)
end

Cake.PdfFixtureGenerator.run()
