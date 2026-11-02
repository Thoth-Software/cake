defmodule Cake.Documents.ParsedDocumentsTest do
  @moduledoc """
  Pins the failure contract of `ParsedDocuments.create_parsed_docs!/1`: its
  inserts run as unlinked tasks, so a task that crashes or times out cannot
  take the caller down by link; instead the bang function raises in the
  caller as the stream is consumed, naming the doc, rather than failing on an
  unmatched `{:exit, _}` (#273).
  """

  use Cake.DataCase, async: true

  import ExUnit.CaptureLog

  alias Cake.Documents.ParsedDocument
  alias Cake.Documents.ParsedDocuments

  defp attrs(overrides) do
    Map.merge(
      %{
        source: "hexdocs",
        version: "1.0.0",
        package: "fine",
        title: "Fine",
        url: "https://example.test/fine",
        text: "some text",
        core: true
      },
      overrides
    )
  end

  describe "create_parsed_docs!/1" do
    test "raises in the caller, naming the doc, when an insert task crashes" do
      # No :text, so the changeset is invalid and insert! raises inside the task.
      crashing = attrs(%{package: "crashing", title: "Crashing", text: nil})
      stream = ParsedDocuments.create_parsed_docs!({:ok, [attrs(%{}), crashing]})

      error = assert_raise RuntimeError, fn -> capture_log(fn -> Enum.to_list(stream) end) end

      assert error.message =~ "crashing@1.0.0"
      assert error.message =~ "Ecto.InvalidChangesetError"
      assert [%ParsedDocument{package: "fine"}] = Repo.all(ParsedDocument)
    end
  end
end
