# PDF fixtures

Small, hand-built PDFs for the Rustler NIF and `Cake.Books.Pdf.Pipeline`
integration tests (#246). They are loaded by name through `Cake.PdfFixtures`
(`test/support/pdf_fixtures.ex`) and exercised only under
`mix test --only integration`.

## Regenerating

Every file here is produced by `generate.exs`, a dependency-free Elixir script
that writes each PDF by hand (PDF 1.4, uncompressed content streams, the
standard Helvetica font, correct xref offsets). Its output is deterministic:
no timestamps or document IDs, so a regeneration is byte-for-byte identical
unless the script changed. From the repository root:

```bash
elixir test/support/fixtures/pdfs/generate.exs
```

Change a fixture by editing the script, never the PDF, then regenerate and
commit both.

## Fixtures

Page text below is what lopdf (via `Cake.ParseBooks.extract_pdf/1`) extracts:
one `BT … ET` block per line, each terminated by `\n`. `page_number` is the
1-based position in the page tree, i.e. the number a PDF viewer shows, not a
printed manuscript page number (see #87).

| File | Pages | Metadata title | What it pins |
|---|---|---|---|
| `multi_page.pdf` | 3, all with text | `Cake Fixture Book` | The happy path: page text, page ordering, the metadata title winning the title fallback chain, `file_hash`/`file_size`/`total_pages`/`word_count`. |
| `blank_pages.pdf` | 4; pages 1 and 3 draw a rectangle and carry no text | none | Blank pages come back as pages with empty text, are rejected before `chunk_index` is assigned (indices stay dense), and, with no text on the first page, the title falls through to the filename. |
| `no_title.pdf` | 2, all with text | none (no Info dictionary) | The middle link of the fallback chain: the title is the first line of the first page. |
| `junk_title.pdf` | 2, all with text | `Rev. 6/07` | A junk-but-present metadata title (the #86 symptom) above a real heading on the first page. Pins the current behaviour — the metadata title is honoured — until #86 decides otherwise. |
| `skipped_page.pdf` | 3; page 2's content stream has a `Tf` operator with no operands | `Partially Extractable` | Partially extractable input: lopdf fails that one page with `syntax error in content stream: missing font operand`, so it lands in `skipped` while pages 1 and 3 extract normally. (lopdf tolerates most other damage — unterminated strings, unbalanced delimiters, binary garbage — and yields an empty page instead, so this is the corruption that reliably errors.) |
| `truncated.pdf` | — | — | The first 256 bytes of `multi_page.pdf`: the header and objects 1–3 (catalog, page tree, font) intact, the cut inside object 4 (the first page), and no page objects, xref table or trailer. Loading fails with `PDF load failed: failed parsing cross reference table: …`, as an `{:error, reason}` tuple, never a crash across the NIF boundary. |

### Extracted text, per fixture

`multi_page.pdf`

```
1: "Cake Fixture Book\nChapter one begins on the first page.\n"
2: "The second page continues the story.\nIt has two lines of text.\n"
3: "The third page ends the book.\n"
```

`blank_pages.pdf`

```
1: ""
2: "Text on page two.\n"
3: ""
4: "Text on page four.\n"
```

`no_title.pdf`

```
1: "Title From The First Line\nBody text below the heading.\n"
2: "Second page of the untitled book.\n"
```

`junk_title.pdf`

```
1: "Sand Filter Installation Manual\nRead all instructions first.\n"
2: "Electrical supply requirements.\n"
```

`skipped_page.pdf`

```
1: "Before the broken page.\n"
2: skipped — "syntax error in content stream: missing font operand"
3: "After the broken page.\n"
```
