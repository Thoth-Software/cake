defmodule Cake.PipelinesSearchBackendTest do
  @moduledoc """
  Pins `Cake.Pipelines.add_to_search_backend/3` against the search-backend
  mock. `test_helper.exs` disables the backend globally, so this module is
  `async: false` and re-enables it for its own tests only.
  """

  use Cake.DataCase, async: false

  import Mox

  alias Cake.FailedIngests.FailedIngest
  alias Cake.Pipelines
  alias Cake.Repo

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

  defp ctx do
    Pipelines.build_context(Cake.Books.Pipeline, Cake.Books.Pdf.Pipeline, "test-model")
  end

  defp doc(id), do: %{id: id, text: "chunk #{id}"}

  describe "add_to_search_backend/3" do
    test "passes indexed documents through and records nothing" do
      expect(Cake.Search.Backend.Mock, :index_document, 2, fn "books", _doc, _id -> :ok end)

      indexed =
        [doc("a"), doc("b")]
        |> Pipelines.add_to_search_backend("books", ctx())
        |> Enum.to_list()

      assert length(indexed) == 2
      assert Repo.all(FailedIngest) == []
    end

    test "records a backend error under the failing document's id" do
      failing_id = Ecto.UUID.generate()
      ok_id = Ecto.UUID.generate()

      expect(Cake.Search.Backend.Mock, :index_document, 2, fn
        "books", _doc, ^failing_id -> {:error, %{"error" => "boom"}}
        "books", _doc, ^ok_id -> :ok
      end)

      indexed =
        [doc(failing_id), doc(ok_id)]
        |> Pipelines.add_to_search_backend("books", ctx())
        |> Enum.to_list()

      assert length(indexed) == 1

      assert [%FailedIngest{} = failure] = Repo.all(FailedIngest)
      assert failure.step == "search_backend.index"
      assert failure.input_identifier == failing_id
      assert failure.error_text =~ "search_backend_api_error"
      assert failure.error_text =~ "boom"
    end

    test "records a timed-out index task under the failing document's id" do
      slow_id = Ecto.UUID.generate()

      ctx =
        Pipelines.build_context(Cake.Books.Pipeline, Cake.Books.Pdf.Pipeline, "test-model",
          search_backend_timeout: 50
        )

      expect(Cake.Search.Backend.Mock, :index_document, fn "books", _doc, ^slow_id ->
        Process.sleep(500)
        :ok
      end)

      indexed =
        [doc(slow_id)]
        |> Pipelines.add_to_search_backend("books", ctx)
        |> Enum.to_list()

      assert indexed == []

      assert [%FailedIngest{} = failure] = Repo.all(FailedIngest)
      assert failure.step == "search_backend.index"
      assert failure.input_identifier == slow_id
      assert failure.error_text =~ "search_backend_exit"
      assert failure.error_text =~ "timeout"
    end
  end
end
