defmodule Cake.Books.AdaptersTest do
  use ExUnit.Case, async: true

  alias Cake.Books.Adapters

  describe "valid_key?/1" do
    test "accepts the keys build_key/3 produces" do
      assert Adapters.valid_key?(Adapters.build_key("books", "getting_started_abc123"))
      assert Adapters.valid_key?("cake-documents/acme/books/x")
    end

    test "accepts legacy path-shaped keys that stay under the root once joined" do
      assert Adapters.valid_key?("legacy/books/handbook.pdf")
      assert Adapters.valid_key?("/absolute/looking/key.pdf")
    end

    test "rejects keys with a .. segment anywhere" do
      refute Adapters.valid_key?("../../etc/passwd")
      refute Adapters.valid_key?("cake-documents/../../../etc/passwd")
      refute Adapters.valid_key?("cake-documents/default/books/..")
    end

    test "rejects empty, blank, NUL-bearing, and non-binary keys" do
      refute Adapters.valid_key?("")
      refute Adapters.valid_key?("   ")
      refute Adapters.valid_key?("books/a\0b")
      refute Adapters.valid_key?(nil)
      refute Adapters.valid_key?(:books)
    end

    test "does not treat a .. inside a segment as traversal" do
      assert Adapters.valid_key?("cake-documents/default/books/notes..final")
    end
  end
end
