defmodule CakeWeb.ChatLive.SelectionFormTest do
  @moduledoc """
  Unit coverage for the document-selection form, pinning the subset validation
  now provided by `Ecto.Changeset.validate_subset/3` (#165).
  """

  use ExUnit.Case, async: true

  alias CakeWeb.ChatLive.SelectionForm

  @available ["doc-a", "doc-b", "doc-c"]

  describe "changeset/2" do
    test "is valid when the selection is a subset of the available ids" do
      assert SelectionForm.changeset(%{"selected_doc_ids" => ["doc-a", "doc-c"]}, @available).valid?
    end

    test "is invalid when a selected id is not in the available set" do
      changeset = SelectionForm.changeset(%{"selected_doc_ids" => ["doc-a", "nope"]}, @available)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :selected_doc_ids)
    end

    test "drops blank ids from the hidden input before validating" do
      assert SelectionForm.changeset(%{"selected_doc_ids" => ["", "doc-b"]}, @available).valid?
    end

    test "an empty or all-blank selection is invalid (found by the property test)" do
      for picks <- [[], [""], ["", ""]] do
        changeset = SelectionForm.changeset(%{"selected_doc_ids" => picks}, @available)

        refute changeset.valid?
        assert Keyword.has_key?(changeset.errors, :selected_doc_ids)
      end
    end
  end
end
