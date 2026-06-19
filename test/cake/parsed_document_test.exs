defmodule Cake.ParsedDocumentTest do
  use Cake.DataCase

  alias Cake.Documents.ParsedDocuments

  describe "parsed_documents" do
    alias Cake.Documents.ParsedDocument

    import Cake.ParsedDocumentFixtures

    @invalid_attrs %{source: nil, version: nil, package: nil, url: nil}

    test "list_parsed_documents/0 returns all parsed_documents" do
      parsed_documents = parsed_documents_fixture()
      assert ParsedDocuments.list_parsed_documents() == [parsed_documents]
    end

    test "get_parsed_documents!/1 returns the parsed_documents with given id" do
      parsed_documents = parsed_documents_fixture()
      assert ParsedDocuments.get_parsed_document!(parsed_documents.id) == parsed_documents
    end

    test "create_parsed_documents/1 with valid data creates a parsed_documents" do
      valid_attrs = %{
        title: "some title",
        package: "some package",
        version: "some version",
        core: true,
        url: "some url",
        text: "some text",
        source: "some source"
      }

      assert {:ok, %ParsedDocument{} = parsed_documents} =
               ParsedDocuments.create_parsed_document(valid_attrs)

      assert parsed_documents.title == "some title"
      assert parsed_documents.package == "some package"
      assert parsed_documents.version == "some version"
      assert parsed_documents.core == true
      assert parsed_documents.url == "some url"
      assert parsed_documents.text == "some text"
      assert parsed_documents.source == "some source"
    end

    test "create_parsed_documents/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = ParsedDocuments.create_parsed_document(@invalid_attrs)
    end

    test "create_parsed_documents/1 without text returns an error requiring text" do
      attrs = %{source: "s", version: "v", package: "p", url: "u", title: "t", core: true}

      assert {:error, changeset} = ParsedDocuments.create_parsed_document(attrs)
      assert "can't be blank" in errors_on(changeset).text
    end

    test "update_parsed_documents/2 with valid data updates the parsed_documents" do
      parsed_documents = parsed_documents_fixture()

      update_attrs = %{
        title: "some updated title",
        package: "some updated package",
        version: "some updated version",
        core: false,
        url: "some updated url",
        text: "some updated text"
      }

      assert {:ok, %ParsedDocument{} = parsed_documents} =
               ParsedDocuments.update_parsed_document(parsed_documents, update_attrs)

      assert parsed_documents.title == "some updated title"
      assert parsed_documents.package == "some updated package"
      assert parsed_documents.version == "some updated version"
      assert parsed_documents.core == false
      assert parsed_documents.url == "some updated url"
      assert parsed_documents.text == "some updated text"
    end

    test "update_parsed_documents/2 with invalid data returns error changeset" do
      parsed_documents = parsed_documents_fixture()

      assert {:error, %Ecto.Changeset{}} =
               ParsedDocuments.update_parsed_document(parsed_documents, @invalid_attrs)

      assert parsed_documents == ParsedDocuments.get_parsed_document!(parsed_documents.id)
    end

    test "delete_parsed_documents/1 deletes the parsed_documents" do
      parsed_documents = parsed_documents_fixture()
      assert {:ok, %ParsedDocument{}} = ParsedDocuments.delete_parsed_document(parsed_documents)

      assert_raise Ecto.NoResultsError, fn ->
        ParsedDocuments.get_parsed_document!(parsed_documents.id)
      end
    end

    test "change_parsed_documents/1 returns a parsed_documents changeset" do
      parsed_documents = parsed_documents_fixture()
      assert %Ecto.Changeset{} = ParsedDocuments.change_parsed_document(parsed_documents)
    end
  end
end
