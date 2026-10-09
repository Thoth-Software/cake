defmodule CakeWeb.UploadLiveTest do
  use CakeWeb.ConnCase, async: true

  import Cake.ZipFixtures
  import ExUnit.CaptureLog
  import Mox
  import Phoenix.LiveViewTest

  alias CakeWeb.UploadLive

  setup :register_and_log_in_user

  describe "authentication" do
    test "redirects to the login page when the user is not authenticated" do
      assert {:error, {:redirect, %{to: path}}} = live(build_conn(), ~p"/upload")
      assert path =~ "/users/log_in"
    end
  end

  describe "mount" do
    test "renders the upload page in idle state", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/upload")

      assert html =~ "Upload Documents"
      assert html =~ "Upload Files"
      assert html =~ "Upload Folder"
      assert html =~ "Upload and Ingest"
    end

    test "submit button is disabled with no files queued", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/upload")

      assert has_element?(view, "button[disabled]", "Upload and Ingest")
    end
  end

  describe "file validation" do
    test "renders queued PDF entry without crashing (regression: entry.errors KeyError)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/upload")

      upload =
        file_input(view, "#upload-form", :documents, [
          %{name: "doc.pdf", content: "fake-pdf-content", type: "application/pdf"}
        ])

      assert {:ok, _} = preflight_upload(upload)

      html = render(view)

      assert html =~ "doc.pdf"
      refute html =~ "File type not accepted"
    end

    test "rejects non-accepted file types at preflight", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/upload")

      upload =
        file_input(view, "#upload-form", :documents, [
          %{name: "readme.txt", content: "not a pdf", type: "text/plain"}
        ])

      assert {:error, [[_ref, :not_accepted]]} = preflight_upload(upload)
    end
  end

  describe "folder upload filtering" do
    test "accepts PDF files from folder upload", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/upload")

      upload =
        file_input(view, "#upload-form", :folder, [
          %{name: "report.pdf", content: "fake-pdf", type: "application/pdf"}
        ])

      assert {:ok, _} = preflight_upload(upload)

      html = render(view)
      assert html =~ "report.pdf"
      refute html =~ "File type not accepted"
    end

    test "rejects non-PDF files from folder upload at preflight", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/upload")

      upload =
        file_input(view, "#upload-form", :folder, [
          %{name: "notes.txt", content: "some text", type: "text/plain"}
        ])

      assert {:error, [[_ref, :not_accepted]]} = preflight_upload(upload)
    end

    test "accepts PDFs and rejects non-PDFs in a mixed folder upload", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/upload")

      pdf_upload =
        file_input(view, "#upload-form", :folder, [
          %{name: "good.pdf", content: "fake-pdf", type: "application/pdf"}
        ])

      assert {:ok, _} = preflight_upload(pdf_upload)

      non_pdf_upload =
        file_input(view, "#upload-form", :folder, [
          %{name: "image.png", content: "fake-png", type: "image/png"}
        ])

      assert {:error, [[_ref, :not_accepted]]} = preflight_upload(non_pdf_upload)
    end
  end

  describe "unreadable archives" do
    # Each archive is rejected on its own, so its reason is the page's error.
    test "explains each rejection in words rather than an Elixir term", %{conn: conn} do
      encrypted = [{"book.pdf", "pdf"}] |> zip_binary() |> forge_flags("book.pdf", 0x0001)

      bzip2 =
        [{"book.pdf", "pdf"}] |> zip_binary() |> forge_compression_method("book.pdf", 12)

      for {archive, message} <- [
            {"not a zip at all", "it is not a ZIP archive, or it is damaged"},
            {encrypted, "book.pdf is password-protected"},
            {bzip2, "book.pdf uses a compression method other than Deflate"}
          ] do
        {:ok, view, _html} = live(conn, ~p"/upload")

        upload =
          file_input(view, "#upload-form", :documents, [
            %{name: "upload.zip", content: archive, type: "application/zip"}
          ])

        render_upload(upload, "upload.zip")
        html = view |> element("#upload-form") |> render_submit()

        assert html =~ "Failed to process upload.zip: " <> message
      end
    end
  end

  describe "ZIP expansion limit" do
    test "rejects an archive whose PDFs declare more than the cap, naming the cap", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/upload")
      cap = Application.fetch_env!(:cake, :max_zip_expanded_bytes)

      # A few hundred bytes on the wire whose central directory claims 3 GB.
      bomb =
        [{"a.pdf", "fake-pdf"}]
        |> zip_binary()
        |> forge_declared_size("a.pdf", 3_000_000_000)

      upload =
        file_input(view, "#upload-form", :documents, [
          %{name: "bomb.zip", content: bomb, type: "application/zip"}
        ])

      assert render_upload(upload, "bomb.zip") =~ "bomb.zip"

      html = view |> element("#upload-form") |> render_submit()

      assert html =~ "Failed to process bomb.zip"
      assert html =~ "over the #{Float.round(cap / 1_048_576, 1)} MB limit"
      assert Process.alive?(view.pid)
      assert render(view) =~ "Failed to process bomb.zip"
    end

    test "ingests the other files and names each rejected archive beside them", %{conn: conn} do
      # The PDF is stored, then read back by the ingest task; failing the
      # read ends ingestion quickly without a real PDF.
      stub(Cake.Books.Adapters.Mock, :write, fn _key, _binary -> :ok end)
      stub(Cake.Books.Adapters.Mock, :read, fn _key -> {:error, :enoent} end)

      {:ok, view, _html} = live(conn, ~p"/upload")
      cap = Application.fetch_env!(:cake, :max_zip_expanded_bytes)
      limit_text = "over the #{Float.round(cap / 1_048_576, 1)} MB limit"

      bomb =
        [{"a.pdf", "fake-pdf"}]
        |> zip_binary()
        |> forge_declared_size("a.pdf", 3_000_000_000)

      # One input per file: LiveViewTest cannot consume two entries of one
      # file_input in a single submit.
      pdf_upload =
        file_input(view, "#upload-form", :folder, [
          %{name: "good.pdf", content: "%PDF-1.7 fake", type: "application/pdf"}
        ])

      zip_upload =
        file_input(view, "#upload-form", :documents, [
          %{name: "bomb.zip", content: bomb, type: "application/zip"}
        ])

      render_upload(pdf_upload, "good.pdf")
      render_upload(zip_upload, "bomb.zip")

      processing_html = view |> element("#upload-form") |> render_submit()

      assert processing_html =~ "Processing documents"
      assert has_element?(view, ~s(#rejected-archives[role="status"]), "bomb.zip")
      assert processing_html =~ "bomb.zip"
      assert processing_html =~ limit_text

      {done_html, _log} = with_log(fn -> render_async(view) end)

      refute done_html =~ "Processing documents"
      assert done_html =~ "bomb.zip"
      assert done_html =~ limit_text
    end
  end

  # A pipeline-fatal ingest error can't be produced through the UI:
  # dispatch_ingestion/2 never calls ingest with an empty key list, and it
  # builds every key itself. So the callback is exercised directly.
  describe "handle_async/3 with a pipeline-fatal ingest error" do
    test "sets an error status naming the reason instead of crashing" do
      reason = {:validate_paths, :no_paths}

      {{:noreply, socket}, log} =
        with_log(fn ->
          UploadLive.handle_async(:ingest, {:ok, {:error, reason}}, %Phoenix.LiveView.Socket{})
        end)

      assert socket.assigns.status == :error
      assert socket.assigns.error == "Ingestion failed: #{inspect(reason)}"
      assert log =~ inspect(reason)
    end
  end
end
