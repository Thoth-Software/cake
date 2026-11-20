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
      {:ok, view, _html} = live(conn, ~p"/upload")

      assert has_element?(view, "#page h1", "Upload documents")
      assert has_element?(view, "#upload-form #upload-dropzone")
      assert has_element?(view, "#upload-form #upload-folder")
      assert has_element?(view, "#upload-submit", "Upload and ingest")

      for id <- ~w(upload-queue upload-working upload-results upload-error rejected-archives) do
        refute has_element?(view, "#" <> id)
      end
    end

    test "submit button is disabled with no files queued", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/upload")

      assert has_element?(view, "#upload-submit[disabled]")
    end

    test "the drop zone states what is accepted and the limits the page enforces", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/upload")

      limits = view |> element("#upload-dropzone #upload-limits") |> render()

      assert limits =~ "PDF"
      assert limits =~ "ZIP"
      assert limits =~ "20 files"
      assert limits =~ "100 MB"
    end

    test "the drop zone hands dropped files to the files input, and the folder option has its own",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/upload")
      html = view |> render() |> Floki.parse_document!()

      assert [files_ref] = Floki.attribute(html, "#upload-dropzone", "phx-drop-target")

      assert [^files_ref] =
               Floki.attribute(html, ~s(#upload-dropzone input[name="documents"]), "id")

      assert [_folder_input] =
               Floki.find(html, ~s(#upload-folder input[name="folder"][webkitdirectory]))

      assert Floki.find(html, ~s(#upload-dropzone input[name="folder"])) == []
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

    test "a queued file shows its name, its size, a progress bar and a remove button", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/upload")

      upload =
        file_input(view, "#upload-form", :documents, [
          %{name: "doc.pdf", content: "fake-pdf-content", type: "application/pdf"}
        ])

      assert {:ok, _} = preflight_upload(upload)

      assert has_element?(view, ~s(#upload-queue [data-part="name"]), "doc.pdf")
      assert has_element?(view, ~s(#upload-queue [data-part="size"]), "16 B")
      assert has_element?(view, ~s(#upload-queue progress[max="100"]))
      refute has_element?(view, ~s(#upload-queue [data-part="error"]))
      refute has_element?(view, "#upload-submit[disabled]")

      view |> element(~s(#upload-queue button[phx-click="cancel-upload"])) |> render_click()

      refute has_element?(view, "#upload-queue")
      assert has_element?(view, "#upload-submit[disabled]")
    end

    test "rejects non-accepted file types at preflight, and says so on the file", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/upload")

      upload =
        file_input(view, "#upload-form", :documents, [
          %{name: "readme.txt", content: "not a pdf", type: "text/plain"}
        ])

      assert {:error, [[ref, :not_accepted]]} = preflight_upload(upload)

      assert has_element?(
               view,
               ~s(#upload-entry-#{ref} [data-part="error"]),
               "File type not accepted"
             )

      # A file that was refused is not uploaded, so it has no progress to show.
      refute has_element?(view, "#upload-entry-#{ref} progress")
    end

    # The browser sends nothing while a queued file is refused, so the button
    # would do nothing: it is disabled, and the page says what to do.
    test "cannot submit while a queued file is refused, until it is removed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/upload")

      good =
        file_input(view, "#upload-form", :documents, [
          %{name: "doc.pdf", content: "fake-pdf-content", type: "application/pdf"}
        ])

      assert {:ok, _} = preflight_upload(good)
      refute has_element?(view, "#upload-blocked")

      bad =
        file_input(view, "#upload-form", :documents, [
          %{name: "readme.txt", content: "not a pdf", type: "text/plain"}
        ])

      assert {:error, [[ref, :not_accepted]]} = preflight_upload(bad)

      assert has_element?(view, "#upload-submit[disabled]")
      assert has_element?(view, "#upload-blocked")

      view
      |> element(~s(#upload-entry-#{ref} button[phx-click="cancel-upload"]))
      |> render_click()

      refute has_element?(view, "#upload-submit[disabled]")
      refute has_element?(view, "#upload-blocked")
    end

    test "says when more files are queued than one upload takes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/upload")

      upload =
        file_input(
          view,
          "#upload-form",
          :documents,
          for(n <- 1..21, do: %{name: "doc#{n}.pdf", content: "fake", type: "application/pdf"})
        )

      assert {:error, [[_upload_ref, :too_many_files]]} = preflight_upload(upload)
      assert has_element?(view, ~s(#upload-queue [data-part="queue-error"]), "Too many files")
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

      assert has_element?(view, "#upload-working")
      assert has_element?(view, ~s(#rejected-archives.alert-warning[role="alert"]), "bomb.zip")
      assert processing_html =~ "These archives were not ingested:"
      assert processing_html =~ "bomb.zip"
      assert processing_html =~ limit_text

      {done_html, _log} = with_log(fn -> render_async(view) end)

      refute has_element?(view, "#upload-working")
      assert done_html =~ "bomb.zip"
      assert done_html =~ limit_text
    end
  end

  describe "the page's error" do
    test "is an error alert, with a way back to the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/upload")

      upload =
        file_input(view, "#upload-form", :documents, [
          %{name: "upload.zip", content: "not a zip at all", type: "application/zip"}
        ])

      render_upload(upload, "upload.zip")
      view |> element("#upload-form") |> render_submit()

      assert has_element?(
               view,
               ~s(#upload-error.alert-error[role="alert"]),
               "Failed to process upload.zip: it is not a ZIP archive, or it is damaged"
             )

      refute has_element?(view, "#upload-form")

      view |> element("#upload-retry") |> render_click()

      assert has_element?(view, "#upload-form")
      refute has_element?(view, "#upload-error")
    end
  end

  describe "while ingesting" do
    setup :ingest_that_fails_to_read

    test "says that it shows no progress, and to keep the tab open", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/upload")
      submit_one_pdf(view)

      assert has_element?(view, ~s(#upload-working[role="status"]))
      assert has_element?(view, "#upload-working #upload-keep-open", "Keep this tab open")
      refute has_element?(view, "#upload-form")

      {_html, _log} = with_log(fn -> render_async(view) end)

      refute has_element?(view, "#upload-working")
      refute has_element?(view, "#upload-keep-open")
    end
  end

  describe "when ingestion finishes" do
    setup :ingest_that_fails_to_read

    test "reports the figures, and that nothing was ingested when nothing was", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/upload")
      submit_one_pdf(view)
      {_html, _log} = with_log(fn -> render_async(view) end)

      assert has_element?(view, ~s(#upload-results [data-part="indexed"]), "0 indexed")
      assert has_element?(view, ~s(#upload-results [data-part="failed"]), "1 failed")
      refute has_element?(view, ~s(#upload-results [data-part="skipped"]))

      assert has_element?(
               view,
               ~s(#upload-results.alert-error[role="alert"]),
               "No items were successfully ingested."
             )
    end

    test "links onward to the chat", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/upload")
      submit_one_pdf(view)
      {_html, _log} = with_log(fn -> render_async(view) end)

      assert has_element?(view, ~s(#upload-onward a[href="/chat"]))
    end

    test "\"Upload more\" goes back to an empty form, and is not the primary button", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/upload")
      submit_one_pdf(view)
      {_html, _log} = with_log(fn -> render_async(view) end)

      assert has_element?(view, "#upload-onward #upload-more", "Upload more")
      refute has_element?(view, "#upload-more.btn-primary")

      view |> element("#upload-more") |> render_click()

      assert has_element?(view, "#upload-form")
      refute has_element?(view, "#upload-queue")
      refute has_element?(view, "#upload-results")
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

  # The PDF is stored, then read back by the ingest task; failing the read
  # ends ingestion quickly, without a real PDF, as one document that failed.
  defp ingest_that_fails_to_read(_context) do
    stub(Cake.Books.Adapters.Mock, :write, fn _key, _binary -> :ok end)
    stub(Cake.Books.Adapters.Mock, :read, fn _key -> {:error, :enoent} end)
    :ok
  end

  defp submit_one_pdf(view) do
    upload =
      file_input(view, "#upload-form", :documents, [
        %{name: "good.pdf", content: "%PDF-1.7 fake", type: "application/pdf"}
      ])

    render_upload(upload, "good.pdf")
    view |> element("#upload-form") |> render_submit()
  end
end
