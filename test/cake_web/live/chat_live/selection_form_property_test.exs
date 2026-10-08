defmodule CakeWeb.ChatLive.SelectionFormPropertyTest do
  @moduledoc """
  Property tests for `CakeWeb.ChatLive.SelectionForm.changeset/2`.

  The form is one predicate: valid exactly when the submitted ids, blanks
  dropped, are a non-empty subset of the candidate ids the UI offered.
  Example tests live in `selection_form_test.exs`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CakeWeb.ChatLive.SelectionForm

  defp doc_id, do: string(:alphanumeric, min_length: 1, max_length: 8)

  # A submission draws from the offered ids, from ids outside them, and from
  # blanks, so both sides of the predicate are reached.
  defp submission do
    gen all(
          available <- uniq_list_of(doc_id(), max_length: 5),
          picks <- list_of(member_of(["", "unknown-id" | available]), max_length: 6)
        ) do
      {available, picks}
    end
  end

  property "valid exactly when the non-blank selection is non-empty and a subset of the available ids" do
    check all({available, picks} <- submission()) do
      changeset = SelectionForm.changeset(%{"selected_doc_ids" => picks}, available)
      non_blank = Enum.reject(picks, &(&1 == ""))

      expected_valid? = non_blank != [] and Enum.all?(non_blank, &(&1 in available))

      assert changeset.valid? == expected_valid?
    end
  end

  property "a valid selection carries exactly the non-blank ids, in submission order" do
    check all({available, picks} <- submission()) do
      changeset = SelectionForm.changeset(%{"selected_doc_ids" => picks}, available)
      non_blank = Enum.reject(picks, &(&1 == ""))

      if changeset.valid? do
        assert Ecto.Changeset.get_change(changeset, :selected_doc_ids) == non_blank
      end
    end
  end
end
