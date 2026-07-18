defmodule CakeWeb.UploadLiveTest do
  use CakeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

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
end
