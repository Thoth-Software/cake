defmodule CakeWeb.ChatLive.QuestionFormPropertyTest do
  @moduledoc """
  Property tests for `CakeWeb.ChatLive.QuestionForm.changeset/1`.

  The form is one predicate: valid exactly when the mode is `auto` or
  `manual` and the question is non-empty *before* NUL bytes are stripped.
  That ordering is the documented contract: a question made only of NUL
  bytes passes validation and comes out as `""`. Example tests live in
  `question_form_test.exs`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CakeWeb.ChatLive.QuestionForm

  # Questions mix printable text with NUL bytes, including NUL-only and
  # empty strings; modes mix the two valid values with junk and absence.
  defp question do
    gen all(
          parts <-
            list_of(one_of([string(:printable, max_length: 6), constant("\0")]), max_length: 6)
        ) do
      Enum.join(parts)
    end
  end

  defp mode, do: member_of(["auto", "manual", "neither", "", nil])

  defp params(question, nil), do: %{"question" => question}
  defp params(question, mode), do: %{"question" => question, "mode" => mode}

  # Ecto's cast treats a blank-after-trim string as empty, so the question
  # counts as present when something other than whitespace survives; NUL is
  # not whitespace, so a NUL-only question is present.
  defp question_present?(question), do: String.trim(question) != ""

  property "valid exactly when the mode is auto or manual and the question is present before sanitising" do
    check all(question <- question(), mode <- mode()) do
      changeset = QuestionForm.changeset(params(question, mode))

      expected_valid? = mode in ["auto", "manual"] and question_present?(question)

      assert changeset.valid? == expected_valid?
    end
  end

  property "a valid question comes out with its NUL bytes removed, even when nothing else remains" do
    check all(question <- question(), mode <- member_of(["auto", "manual"])) do
      changeset = QuestionForm.changeset(params(question, mode))

      if changeset.valid? do
        assert Ecto.Changeset.get_change(changeset, :question) ==
                 String.replace(question, "\0", "")
      end
    end
  end
end
