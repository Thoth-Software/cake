defmodule Cake.PdfFixtures do
  @moduledoc """
  Loads the fixture PDFs under `test/support/fixtures/pdfs/` by name for the
  Rustler NIF and `Cake.Books.Pdf.Pipeline` integration tests (#246). The
  README in that directory says what each fixture pins and how to regenerate
  it; `fixture_names/0` is the authoritative list.

  Not an Ecto fixture module: nothing here touches the database. Import it
  per test, like the other fixture modules.
  """

  @typedoc "The fixtures on disk, by basename without the `.pdf` extension."
  @type name :: :multi_page | :blank_pages | :no_title | :junk_title | :skipped_page | :truncated

  @doc "Every fixture name, in the order the fixtures README lists them."
  @spec fixture_names() :: [name()]
  def fixture_names, do: raise("Cake.PdfFixtures.fixture_names/0 is not implemented (#246)")

  @doc "The absolute path of the named fixture (for staging it through a storage adapter)."
  @spec fixture_path(name()) :: Path.t()
  def fixture_path(_name), do: raise("Cake.PdfFixtures.fixture_path/1 is not implemented (#246)")

  @doc "The named fixture's bytes, as `Cake.ParseBooks.extract_pdf/1` takes them."
  @spec fixture_binary(name()) :: binary()
  def fixture_binary(_name),
    do: raise("Cake.PdfFixtures.fixture_binary/1 is not implemented (#246)")
end
