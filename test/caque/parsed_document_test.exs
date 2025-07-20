defmodule Caque.ParsedDocumentTest do
  use Caque.DataCase

  alias Caque.ParsedDocument

  describe "parsed_documents" do
    alias Caque.ParsedDocument.ParsedDocuments

    import Caque.ParsedDocumentFixtures

    @invalid_attrs %{function: nil, module: nil, version: nil, core: nil, url: nil, contenet: nil}

    test "list_parsed_documents/0 returns all parsed_documents" do
      parsed_documents = parsed_documents_fixture()
      assert ParsedDocument.list_parsed_documents() == [parsed_documents]
    end

    test "get_parsed_documents!/1 returns the parsed_documents with given id" do
      parsed_documents = parsed_documents_fixture()
      assert ParsedDocument.get_parsed_documents!(parsed_documents.id) == parsed_documents
    end

    test "create_parsed_documents/1 with valid data creates a parsed_documents" do
      valid_attrs = %{function: "some function", module: "some module", version: "some version", core: true, url: "some url", contenet: "some contenet"}

      assert {:ok, %ParsedDocuments{} = parsed_documents} = ParsedDocument.create_parsed_documents(valid_attrs)
      assert parsed_documents.function == "some function"
      assert parsed_documents.module == "some module"
      assert parsed_documents.version == "some version"
      assert parsed_documents.core == true
      assert parsed_documents.url == "some url"
      assert parsed_documents.contenet == "some contenet"
    end

    test "create_parsed_documents/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = ParsedDocument.create_parsed_documents(@invalid_attrs)
    end

    test "update_parsed_documents/2 with valid data updates the parsed_documents" do
      parsed_documents = parsed_documents_fixture()
      update_attrs = %{function: "some updated function", module: "some updated module", version: "some updated version", core: false, url: "some updated url", contenet: "some updated contenet"}

      assert {:ok, %ParsedDocuments{} = parsed_documents} = ParsedDocument.update_parsed_documents(parsed_documents, update_attrs)
      assert parsed_documents.function == "some updated function"
      assert parsed_documents.module == "some updated module"
      assert parsed_documents.version == "some updated version"
      assert parsed_documents.core == false
      assert parsed_documents.url == "some updated url"
      assert parsed_documents.contenet == "some updated contenet"
    end

    test "update_parsed_documents/2 with invalid data returns error changeset" do
      parsed_documents = parsed_documents_fixture()
      assert {:error, %Ecto.Changeset{}} = ParsedDocument.update_parsed_documents(parsed_documents, @invalid_attrs)
      assert parsed_documents == ParsedDocument.get_parsed_documents!(parsed_documents.id)
    end

    test "delete_parsed_documents/1 deletes the parsed_documents" do
      parsed_documents = parsed_documents_fixture()
      assert {:ok, %ParsedDocuments{}} = ParsedDocument.delete_parsed_documents(parsed_documents)
      assert_raise Ecto.NoResultsError, fn -> ParsedDocument.get_parsed_documents!(parsed_documents.id) end
    end

    test "change_parsed_documents/1 returns a parsed_documents changeset" do
      parsed_documents = parsed_documents_fixture()
      assert %Ecto.Changeset{} = ParsedDocument.change_parsed_documents(parsed_documents)
    end
  end
end
