defmodule Cake.ParseBooksPropertyTest do
  @moduledoc """
  The one property the NIF boundary must hold for any input: every call to
  `Cake.ParseBooks.extract_pdf/1` returns a result tuple. A panic inside the
  crate would surface as a raised `ErlangError`, and a bad PDF must never
  take the scheduler down with it (#246). Tagged `:integration` with the
  example tests in `Cake.ParseBooksTest`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Cake.PdfFixtures

  alias Cake.Books.PdfExtraction
  alias Cake.ParseBooks

  @moduletag :integration

  defp result_tuple?({:ok, %PdfExtraction{}}), do: true
  defp result_tuple?({:error, reason}) when is_binary(reason), do: true
  defp result_tuple?(_other), do: false

  property "any prefix of a valid PDF yields a result tuple, never a crash" do
    pdf = fixture_binary(:multi_page)

    check all(length <- integer(0..byte_size(pdf))) do
      assert pdf |> binary_part(0, length) |> ParseBooks.extract_pdf() |> result_tuple?()
    end
  end

  property "arbitrary bytes yield {:error, reason} with a string reason" do
    check all(bytes <- binary(), not String.contains?(bytes, "%PDF")) do
      assert {:error, reason} = ParseBooks.extract_pdf(bytes)
      assert is_binary(reason) and reason != ""
    end
  end

  property "every fixture loads to a result tuple" do
    check all(name <- member_of(fixture_names())) do
      assert name |> fixture_binary() |> ParseBooks.extract_pdf() |> result_tuple?()
    end
  end
end
