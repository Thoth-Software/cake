defmodule Cake.Documents.Hexdocs.HexdocPropertyTest do
  @moduledoc """
  Property tests for the dupe-detection primitive on the Hexdocs context.

  Pins the invariant that `hexdoc_exists?/2` recognizes the (module, version)
  natural key of any persisted hexdoc. Example tests live in `hexdocs_test.exs`
  and `hexdoc_test.exs`.
  """

  use Cake.DataCase, async: true
  use ExUnitProperties

  import Cake.HexdocsFixtures

  alias Cake.Documents.Hexdocs

  describe "hexdoc_exists?/2" do
    property "is true for the (module, version) of any persisted hexdoc" do
      check all(
              module <- string(:alphanumeric, min_length: 1),
              version <- string(:alphanumeric, min_length: 1)
            ) do
        hexdoc_fixture(%{module: module, version: version})
        assert Hexdocs.hexdoc_exists?(module, version)
      end
    end
  end
end
