defmodule Cake.PipelinesSearchBackendPropertyTest do
  @moduledoc """
  Property tests for `Cake.Pipelines.add_to_search_backend/3` over the
  search-backend mock.

  Pins the crash guarantee of #273: whichever documents' index tasks crash,
  the stream carries on, every other document is indexed, and exactly the
  crashed documents are recorded under `"search_backend.index"`, keyed by
  their ids, with the exception in `error_text`.

  `async: false` for the same reason as `Cake.PipelinesSearchBackendTest`:
  `test_helper.exs` disables the backend globally, and this module
  re-enables it for its own tests only.
  """

  use Cake.DataCase, async: false
  use ExUnitProperties

  import ExUnit.CaptureLog
  import Mox

  alias Cake.FailedIngests
  alias Cake.Pipelines

  setup :verify_on_exit!

  setup do
    original_skip = Application.get_env(:cake, :skip_search_backend)
    original_backend = Application.get_env(:cake, :search_backend)
    Application.put_env(:cake, :skip_search_backend, false)
    Application.put_env(:cake, :search_backend, Cake.Search.Backend.Mock)

    on_exit(fn ->
      Application.put_env(:cake, :skip_search_backend, original_skip)
      Application.put_env(:cake, :search_backend, original_backend)
    end)

    :ok
  end

  # A batch of documents with fresh ids, and the subset whose index task
  # will crash (possibly none, possibly all).
  defp docs_with_crashing_subset do
    gen all(crash_flags <- list_of(boolean(), max_length: 6)) do
      docs = Enum.map(crash_flags, fn _flag -> %{id: Ecto.UUID.generate(), text: "chunk"} end)

      crashing =
        docs
        |> Enum.zip(crash_flags)
        |> Enum.filter(fn {_doc, crashes?} -> crashes? end)
        |> MapSet.new(fn {doc, _crashes?} -> doc.id end)

      {docs, crashing}
    end
  end

  property "a crashed index task never aborts the run: survivors are indexed, crashes recorded by id" do
    check all({docs, crashing} <- docs_with_crashing_subset(), max_runs: 25) do
      ctx = Pipelines.build_context(Cake.Books.Pipeline, Cake.Books.Pdf.Pipeline, "test-model")

      stub(Cake.Search.Backend.Mock, :index_document, fn "books", _doc, id ->
        if MapSet.member?(crashing, id), do: raise("index task crashed"), else: :ok
      end)

      {indexed, _log} =
        with_log(fn ->
          docs
          |> Pipelines.add_to_search_backend("books", ctx)
          |> Enum.to_list()
        end)

      assert length(indexed) == length(docs) - MapSet.size(crashing)

      failures = FailedIngests.list_failed_ingests_for_run(ctx.run_id)
      assert length(failures) == MapSet.size(crashing)
      assert MapSet.new(failures, & &1.input_identifier) == crashing
      assert Enum.all?(failures, &(&1.step == "search_backend.index"))
      assert Enum.all?(failures, &(&1.error_text =~ "RuntimeError"))
    end
  end
end
