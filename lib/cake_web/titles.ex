defmodule CakeWeb.Titles do
  @moduledoc """
  How a document's title is displayed, the same on every screen that shows
  one: the chat's citations and candidates, the documents list and a
  document's page.

  A title comes from the parser as it found it in the file. `display/1`
  removes what is never meant to be seen and corrects nothing else: a title
  the parser got wrong is shown wrong (#86). `display_citation_label/1` is
  the same for a citation's label, with its page spelled out.
  """

  # What a document is called when it has no title that can be shown.
  @untitled "Untitled"

  @doc """
  Returns `title` as a screen shows it.

  Control characters and the Unicode replacement character are removed,
  Word's "Microsoft Word - " prefix is dropped, and the ends are trimmed.
  Nothing else is touched: a title that mentions a page ("Style Guide,
  p. 2 errata") keeps its wording. A missing title
  is "Untitled", and so is one with nothing left in it: a title is a link
  and a heading, and an empty one could be neither clicked nor read.

  ## Examples

      iex> CakeWeb.Titles.display("Microsoft Word - Annual Report ")
      "Annual Report"

      iex> CakeWeb.Titles.display(nil)
      "Untitled"

      iex> CakeWeb.Titles.display("\uFFFD")
      "Untitled"
  """
  @spec display(String.t() | nil) :: String.t()
  def display(title) when is_binary(title) do
    title
    |> String.replace(~r/[\x{fffd}\x{0}-\x{1f}]+/u, "")
    |> String.replace(~r/^Microsoft Word - /, "")
    |> String.trim()
    |> untitled_if_empty()
  end

  def display(nil), do: @untitled

  @doc """
  Returns a citation's label as the chat shows it.

  A citation's label is a document's title followed by ", p. N", put
  together by the citation and not stored anywhere. It is cleaned as
  `display/1` cleans a title, and its page is spelled out: ", p. N" reads
  ", PDF page N". Only a label gets this; a stored title is shown with
  `display/1`, which leaves a ", p. N" of its own alone.

  ## Examples

      iex> CakeWeb.Titles.display_citation_label("Annual Report, p. 12")
      "Annual Report, PDF page 12"

      iex> CakeWeb.Titles.display_citation_label(nil)
      "Untitled"
  """
  @spec display_citation_label(String.t() | nil) :: String.t()
  def display_citation_label(label) do
    label
    |> display()
    |> String.replace(~r/, p\. (\d+)/, ", PDF page \\1")
  end

  defp untitled_if_empty(""), do: @untitled
  defp untitled_if_empty(shown), do: shown
end
