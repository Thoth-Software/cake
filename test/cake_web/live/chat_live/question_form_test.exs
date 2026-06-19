defmodule CakeWeb.ChatLive.QuestionFormTest do
  @moduledoc """
  Unit coverage for the chat question form, including the `sanitize_text_fields/1`
  hook gained by switching to `use Cake.Schema` (#165).
  """

  use ExUnit.Case, async: true

  alias CakeWeb.ChatLive.QuestionForm

  describe "changeset/1" do
    test "is valid with a question and a mode" do
      assert QuestionForm.changeset(%{"question" => "hello", "mode" => "auto"}).valid?
    end

    test "requires both question and mode" do
      changeset = QuestionForm.changeset(%{})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :question)
      assert Keyword.has_key?(changeset.errors, :mode)
    end

    test "strips NUL bytes from the question via sanitize_text_fields/1" do
      changeset = QuestionForm.changeset(%{"question" => "a\0b", "mode" => "manual"})

      assert Ecto.Changeset.get_change(changeset, :question) == "ab"
    end
  end
end
