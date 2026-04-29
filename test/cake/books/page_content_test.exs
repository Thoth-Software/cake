defmodule Cake.Books.PageContentTest do
  @moduledoc """
  Smoke tests for the `Cake.Books.PageContent` plain struct. The struct is
  decoded into by the Rust NIF; full ingest-path coverage is deferred until
  fixture PDFs and a NIF mocking strategy land (see #112's description).
  """

  use ExUnit.Case, async: true

  alias Cake.Books.PageContent

  describe "%PageContent{}" do
    test "can be constructed with the documented fields" do
      page = %PageContent{page_number: 7, text: "hello"}

      assert page.page_number == 7
      assert page.text == "hello"
    end

    test "field defaults are nil" do
      assert %PageContent{page_number: nil, text: nil} == %PageContent{}
    end
  end
end
