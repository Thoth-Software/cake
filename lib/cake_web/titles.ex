defmodule CakeWeb.Titles do
  @moduledoc """
  How a document's title is displayed, the same on every screen that shows
  one: the chat's citations and candidates, the documents list and a
  document's page.

  A title comes from the parser as it found it in the file. `display/1`
  removes what is never meant to be seen and corrects nothing else: a title
  the parser got wrong is shown wrong (#86).
  """

  @doc """
  Returns `title` as a screen shows it.

  Control characters and the Unicode replacement character are removed,
  Word's "Microsoft Word - " prefix is dropped, a citation label's
  ", p. N" reads ", PDF page N", and the ends are trimmed. A missing title
  is "Untitled"; a title with nothing left in it is the empty string.

  ## Examples

      iex> CakeWeb.Titles.display("Microsoft Word - Annual Report ")
      "Annual Report"

      iex> CakeWeb.Titles.display("Annual Report, p. 12")
      "Annual Report, PDF page 12"

      iex> CakeWeb.Titles.display(nil)
      "Untitled"
  """
  @spec display(String.t() | nil) :: String.t()
  def display(title) when is_binary(title) do
    title
    |> String.replace(~r/[\x{fffd}\x{0}-\x{1f}]+/u, "")
    |> String.replace(~r/^Microsoft Word - /, "")
    |> String.replace(~r/, p\. (\d+)/, ", PDF page \\1")
    |> String.trim()
  end

  def display(nil), do: "Untitled"
end
