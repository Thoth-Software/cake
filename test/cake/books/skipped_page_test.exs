defmodule Cake.Books.SkippedPageTest do
  @moduledoc """
  Smoke tests for the `Cake.Books.SkippedPage` plain struct. The struct is
  decoded into by the Rust NIF; the decoding itself is pinned against
  fixture PDFs in `Cake.ParseBooksTest` (`mix test --only integration`).
  """

  use ExUnit.Case, async: true

  alias Cake.Books.SkippedPage

  describe "%SkippedPage{}" do
    test "can be constructed with the documented fields" do
      skipped = %SkippedPage{page_number: 12, reason: "image-only page"}

      assert skipped.page_number == 12
      assert skipped.reason == "image-only page"
    end

    test "field defaults are nil" do
      assert %SkippedPage{page_number: nil, reason: nil} == %SkippedPage{}
    end
  end
end
