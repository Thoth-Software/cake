defmodule Caque.HexdocsTest do
  use Caque.DataCase

  alias Caque.Hexdocs

  describe "hexdocs" do
    alias Caque.Hexdocs.Hexdoc

    import Caque.HexdocsFixtures

    @invalid_attrs %{module: nil, version: nil, core: nil, url: nil, content: nil}

    test "list_hexdocs/0 returns all hexdocs" do
      hexdoc = hexdoc_fixture()
      assert Hexdocs.list_hexdocs() == [hexdoc]
    end

    test "get_hexdoc!/1 returns the hexdoc with given id" do
      hexdoc = hexdoc_fixture()
      assert Hexdocs.get_hexdoc!(hexdoc.id) == hexdoc
    end

    test "create_hexdoc/1 with valid data creates a hexdoc" do
      valid_attrs = %{
        module: "some module",
        version: "some version",
        core: true,
        url: "some url",
        content: "some content"
      }

      assert {:ok, %Hexdoc{} = hexdoc} = Hexdocs.create_hexdoc(valid_attrs)
      assert hexdoc.module == "some module"
      assert hexdoc.version == "some version"
      assert hexdoc.core == true
      assert hexdoc.url == "some url"
      assert hexdoc.content == "some content"
    end

    test "create_hexdoc/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Hexdocs.create_hexdoc(@invalid_attrs)
    end

    test "update_hexdoc/2 with valid data updates the hexdoc" do
      hexdoc = hexdoc_fixture()

      update_attrs = %{
        module: "some updated module",
        version: "some updated version",
        core: false,
        url: "some updated url",
        content: "some updated content"
      }

      assert {:ok, %Hexdoc{} = hexdoc} = Hexdocs.update_hexdoc(hexdoc, update_attrs)
      assert hexdoc.module == "some updated module"
      assert hexdoc.version == "some updated version"
      assert hexdoc.core == false
      assert hexdoc.url == "some updated url"
      assert hexdoc.content == "some updated content"
    end

    test "update_hexdoc/2 with invalid data returns error changeset" do
      hexdoc = hexdoc_fixture()
      assert {:error, %Ecto.Changeset{}} = Hexdocs.update_hexdoc(hexdoc, @invalid_attrs)
      assert hexdoc == Hexdocs.get_hexdoc!(hexdoc.id)
    end

    test "delete_hexdoc/1 deletes the hexdoc" do
      hexdoc = hexdoc_fixture()
      assert {:ok, %Hexdoc{}} = Hexdocs.delete_hexdoc(hexdoc)
      assert_raise Ecto.NoResultsError, fn -> Hexdocs.get_hexdoc!(hexdoc.id) end
    end

    test "change_hexdoc/1 returns a hexdoc changeset" do
      hexdoc = hexdoc_fixture()
      assert %Ecto.Changeset{} = Hexdocs.change_hexdoc(hexdoc)
    end
  end
end
