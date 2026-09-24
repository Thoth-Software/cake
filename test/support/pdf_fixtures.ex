defmodule Cake.PdfFixtures do
  @moduledoc """
  Loads the fixture PDFs under `test/support/fixtures/pdfs/` by name for the
  Rustler NIF and `Cake.Books.Pdf.Pipeline` integration tests (#246). The
  README in that directory says what each fixture pins and how to regenerate
  it; `fixture_names/0` is the authoritative list.

  Not an Ecto fixture module: nothing here touches the database. Import it
  per test, like the other fixture modules.
  """

  @fixtures_dir Path.expand("fixtures/pdfs", __DIR__)
  @names [:multi_page, :blank_pages, :no_title, :junk_title, :skipped_page, :truncated]

  @typedoc "The fixtures on disk, by basename without the `.pdf` extension."
  @type name :: :multi_page | :blank_pages | :no_title | :junk_title | :skipped_page | :truncated

  @doc "Every fixture name, in the order the fixtures README lists them."
  @spec fixture_names() :: [name()]
  def fixture_names, do: @names

  @doc """
  The absolute path of the named fixture (for staging it through a storage
  adapter). Raises `ArgumentError` for a name not in `fixture_names/0`.
  """
  @spec fixture_path(name()) :: Path.t()
  def fixture_path(name) when name in @names do
    Path.join(@fixtures_dir, "#{name}.pdf")
  end

  def fixture_path(name) do
    raise ArgumentError,
          "unknown PDF fixture #{inspect(name)}; known: #{inspect(@names)}"
  end

  @doc "The named fixture's bytes, as `Cake.ParseBooks.extract_pdf/1` takes them."
  @spec fixture_binary(name()) :: binary()
  def fixture_binary(name), do: name |> fixture_path() |> File.read!()
end
