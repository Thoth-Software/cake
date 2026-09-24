defmodule Mix.Tasks.Cake.Nif.Check do
  @shortdoc "Proves the parsebooks NIF loads here by extracting a PDF through it"

  @moduledoc """
  Loads the `parsebooks` Rustler NIF and runs `Cake.ParseBooks.extract_pdf/1`
  over the PDF at the given path, printing a one-line summary of what it
  extracted:

      mix cake.nif.check test/support/fixtures/pdfs/multi_page.pdf
      NIF ok: test/support/fixtures/pdfs/multi_page.pdf: title "Cake Fixture Book", 3 pages (3 extracted, 0 skipped), 28 words

  The point is the load, not the parse. `Cake.ParseBooks` loads
  `priv/native/libparsebooks.so` on first use, and that `.so` has to have
  been compiled for the machine running this command. The docker-compose
  smoke test (`ci/compose_smoke.sh`, #250) runs this inside the app container
  to prove that `entrypoint.sh`'s forced-recompile sequence produced a
  loadable Linux NIF rather than a stale host-compiled one (CLAUDE.md "NIF
  clobbering"); it is as useful on a host where the app reports
  `module not available` or `:nif_not_loaded`, which is what this command
  crashes with when the NIF does not load.

  Exits non-zero (a `Mix.Error`) when the file cannot be read or when the
  extraction returns `{:error, reason}`: a truncated PDF is an error, not a
  crash, and is reported as one. Does not start the application: the NIF
  needs only the compiled code, and starting the application here would
  race a running Phoenix server for its port.
  """

  use Boundary, top_level?: true, deps: [Cake]
  use Mix.Task

  @typedoc "Runs the extraction: `Cake.ParseBooks.extract_pdf/1`, or a test double."
  @type extractor :: (binary() -> {:ok, Cake.Books.PdfExtraction.t()} | {:error, String.t()})

  @typedoc """
  What a successful check reports: `pages` is `extracted` plus `skipped`, and
  `words` counts whitespace-separated words over the extracted pages.
  """
  @type summary :: %{
          path: Path.t(),
          title: String.t() | nil,
          pages: non_neg_integer(),
          extracted: non_neg_integer(),
          skipped: non_neg_integer(),
          words: non_neg_integer()
        }

  @impl Mix.Task
  @spec run([binary()]) :: :ok
  def run([path]) do
    # Compiled code and config only, no application start (see @moduledoc).
    _ = Mix.Task.run("app.config")

    case check(path, &Cake.ParseBooks.extract_pdf/1) do
      {:ok, summary} -> Mix.shell().info(format(summary))
      {:error, reason} -> Mix.raise("mix cake.nif.check: #{reason}")
    end
  end

  def run(_args) do
    Mix.raise("usage: mix cake.nif.check PATH (a PDF to extract through the NIF)")
  end

  @doc """
  Reads the PDF at `path`, hands its bytes to `extractor`, and summarizes the
  extraction. Errors are messages ready to print: an unreadable path never
  reaches the extractor, and an extractor `{:error, reason}` is reported
  with its reason.
  """
  @spec check(Path.t(), extractor()) :: {:ok, summary()} | {:error, String.t()}
  def check(path, extractor) when is_binary(path) and is_function(extractor, 1) do
    with {:ok, binary} <- read(path),
         {:ok, extraction} <- extract(binary, extractor) do
      {:ok, summarize(path, extraction)}
    end
  end

  @doc "The one-line report `run/1` prints for a summary."
  @spec format(summary()) :: String.t()
  def format(%{
        path: path,
        title: title,
        pages: pages,
        extracted: extracted,
        skipped: skipped,
        words: words
      }) do
    "NIF ok: #{path}: #{format_title(title)}, #{pages} pages " <>
      "(#{extracted} extracted, #{skipped} skipped), #{words} words"
  end

  @spec format_title(String.t() | nil) :: String.t()
  defp format_title(nil), do: "no title"
  defp format_title(title), do: ~s(title "#{title}")

  @spec read(Path.t()) :: {:ok, binary()} | {:error, String.t()}
  defp read(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  @spec extract(binary(), extractor()) ::
          {:ok, Cake.Books.PdfExtraction.t()} | {:error, String.t()}
  defp extract(binary, extractor) do
    case extractor.(binary) do
      {:ok, extraction} -> {:ok, extraction}
      {:error, reason} -> {:error, "extraction failed: #{reason}"}
    end
  end

  # Read as the map it is rather than matched as a struct: Cake.Books does not
  # export PdfExtraction, and this task depends on the Cake boundary only.
  @spec summarize(Path.t(), Cake.Books.PdfExtraction.t()) :: summary()
  defp summarize(path, %{title: title, pages: pages, skipped: skipped})
       when is_list(pages) and is_list(skipped) do
    %{
      path: path,
      title: title,
      pages: length(pages) + length(skipped),
      extracted: length(pages),
      skipped: length(skipped),
      words: pages |> Enum.map(&word_count/1) |> Enum.sum()
    }
  end

  @spec word_count(Cake.Books.PageContent.t()) :: non_neg_integer()
  defp word_count(%{text: text}), do: text |> String.split() |> length()
end
