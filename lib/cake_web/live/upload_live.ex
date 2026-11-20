defmodule CakeWeb.UploadLive do
  @moduledoc """
  Book-upload UI. Accepts PDF and ZIP uploads (ZIPs are unpacked to PDFs
  via `Cake.Books.ZipExtractor`), stores each file through the configured
  `Cake.Books.Adapters` adapter, and runs Books ingestion
  (`Cake.Books.Pipeline.ingest/4` with `Cake.Books.Pdf.Pipeline`) as an
  async task.

  The upload limits (20 archives of up to 100 MB each) bound compressed
  bytes only; how far an archive may expand is bounded by
  `Cake.Books.ZipExtractor` (`config :cake, :max_zip_expanded_bytes` and
  `:max_zip_entries`), and an archive it rejects is reported with the
  limit it broke: as the page's error when nothing else in the batch can be
  ingested, otherwise in a warning listing each rejected archive beside the
  ingestion of the rest.

  Ingestion runs in a task this LiveView owns and reports nothing until it
  is done, so the page says both while it runs: that there is no progress
  to show, and to keep the tab open on this page. The screen is built from
  the shared pieces (`Layouts.app`, `header/1`, `working/1`, `notice/1`);
  `.claude/rules/front-end.md`, "Look and feel".
  """

  use CakeWeb, :live_view

  alias Cake.Books.Adapters
  alias Cake.Books.ZipExtractor

  require Logger

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> allow_upload(:documents,
       accept: ~w(.pdf .zip),
       max_entries: 20,
       max_file_size: 100_000_000
     )
     |> allow_upload(:folder,
       accept: ~w(.pdf),
       max_entries: 200,
       max_file_size: 100_000_000
     )
     |> assign(
       page_title: "Upload",
       status: :idle,
       results: nil,
       error: nil,
       skipped_count: 0,
       rejected_archives: []
     )}
  end

  @impl Phoenix.LiveView
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel-upload", %{"ref" => ref, "upload" => upload_name}, socket) do
    {:noreply, cancel_upload(socket, String.to_existing_atom(upload_name), ref)}
  end

  def handle_event("upload", _params, socket) do
    all_results = consume_all_uploads(socket)
    dispatch_ingestion(socket, all_results)
  end

  def handle_event("reset", _params, socket) do
    {:noreply,
     assign(socket,
       status: :idle,
       results: nil,
       error: nil,
       skipped_count: 0,
       rejected_archives: []
     )}
  end

  # What the function given to `start_async` in dispatch_ingestion/2 returns,
  # which is `Cake.Books.Pipeline.ingest/4`'s result. The `:ok` payload is ours
  # to narrow because this module produced it; the `:exit` reason comes from
  # the runtime and stays `term()`.
  @typep ingest_result ::
           {:ok, Cake.Pipelines.ingest_summary()}
           | {:error, {:no_items_ingested, Cake.Pipelines.ingest_summary()}}
           | {:error, {:validate_paths, Cake.Books.Pipeline.path_error()}}

  @impl Phoenix.LiveView
  @spec handle_async(
          :ingest,
          {:ok, ingest_result()} | {:exit, term()},
          Phoenix.LiveView.Socket.t()
        ) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_async(:ingest, {:ok, {:ok, summary}}, socket) do
    {:noreply, assign(socket, status: :done, results: summary)}
  end

  def handle_async(:ingest, {:ok, {:error, {:no_items_ingested, summary}}}, socket) do
    {:noreply,
     assign(socket,
       status: :done,
       results: summary,
       error: "No items were successfully ingested."
     )}
  end

  def handle_async(:ingest, {:ok, {:error, reason}}, socket) do
    Logger.warning("UploadLive ingestion failed: #{inspect(reason)}")

    {:noreply, assign(socket, status: :error, error: "Ingestion failed: #{inspect(reason)}")}
  end

  def handle_async(:ingest, {:exit, reason}, socket) do
    Logger.error("UploadLive ingestion task crashed: #{inspect(reason)}")

    {:noreply,
     assign(socket, status: :error, error: "Ingestion failed unexpectedly. Please try again.")}
  end

  @typep upload_result ::
           {:pdf, [String.t()]}
           | {:zip_empty, String.t()}
           | {:zip_error, {String.t(), ZipExtractor.error()}}
           | {:skipped, String.t()}

  # An archive the batch could not use, with why: the extractor's error, or
  # the one sentence collect_zip_errors/1 writes for an archive with no PDFs.
  @typep archive_rejection :: {String.t(), ZipExtractor.error() | String.t()}

  @spec consume_all_uploads(Phoenix.LiveView.Socket.t()) :: [upload_result()]
  # sobelow_skip ["Traversal.FileModule"]
  # `tmp_path` is the temp file Phoenix LiveView writes each upload to; it is
  # framework-generated, not a client-supplied path.
  defp consume_all_uploads(socket) do
    adapter = Adapters.adapter()

    document_results =
      consume_uploaded_entries(socket, :documents, fn %{path: tmp_path}, entry ->
        binary = File.read!(tmp_path)
        {:ok, process_document_entry(entry.client_name, binary, adapter)}
      end)

    folder_results =
      consume_uploaded_entries(socket, :folder, fn %{path: tmp_path}, entry ->
        binary = File.read!(tmp_path)
        {:ok, process_folder_entry(entry.client_name, binary, adapter)}
      end)

    List.flatten(document_results ++ folder_results)
  end

  @spec dispatch_ingestion(Phoenix.LiveView.Socket.t(), [upload_result()]) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  defp dispatch_ingestion(socket, all_results) do
    all_keys = collect_keys(all_results)
    skipped = Enum.count(all_results, &match?({:skipped, _}, &1))
    zip_errors = collect_zip_errors(all_results)

    cond do
      all_keys == [] and zip_errors != [] ->
        [{name, reason} | _] = zip_errors

        {:noreply,
         assign(socket,
           status: :error,
           error: "Failed to process #{name}: #{describe_zip_error(reason)}"
         )}

      all_keys == [] ->
        {:noreply,
         assign(socket, status: :error, error: "No PDF files found in the uploaded files.")}

      true ->
        socket =
          socket
          |> assign(
            status: :processing,
            skipped_count: skipped,
            rejected_archives: Enum.map(zip_errors, &describe_rejected_archive/1)
          )
          |> start_async(:ingest, fn ->
            provider = Application.fetch_env!(:cake, :default_provider)
            model = Application.fetch_env!(:cake, :default_embedding_model)
            Cake.Books.Pipeline.ingest(provider, Cake.Books.Pdf.Pipeline, model, all_keys)
          end)

        {:noreply, socket}
    end
  end

  @spec collect_keys([upload_result()]) :: [String.t()]
  defp collect_keys(results) do
    Enum.flat_map(results, fn
      {:pdf, keys} -> keys
      _ -> []
    end)
  end

  @spec collect_zip_errors([upload_result()]) :: [archive_rejection()]
  defp collect_zip_errors(results) do
    Enum.flat_map(results, fn
      {:zip_error, info} -> [info]
      {:zip_empty, name} -> [{name, "ZIP contained no PDF files"}]
      _ -> []
    end)
  end

  # Archives rejected in a batch whose other files still go on to ingestion.
  @spec describe_rejected_archive(archive_rejection()) :: String.t()
  defp describe_rejected_archive({name, reason}), do: "#{name}: #{describe_zip_error(reason)}"

  @spec describe_zip_error(ZipExtractor.error() | String.t()) :: String.t()
  defp describe_zip_error({:too_large, declared, max_bytes}) do
    "its PDFs would expand to #{format_size(declared)}, " <>
      "over the #{format_size(max_bytes)} limit for one archive"
  end

  defp describe_zip_error({:too_many_entries, count, max_entries}) do
    "it holds #{count} entries, over the limit of #{max_entries}"
  end

  defp describe_zip_error({:size_mismatch, entry_name}) do
    "#{entry_name} does not expand to the size the archive declares for it"
  end

  defp describe_zip_error(:not_a_zip), do: "it is not a ZIP archive, or it is damaged"
  defp describe_zip_error(:bad_central_directory), do: "its file index is damaged"

  defp describe_zip_error(:multiple_disks_not_supported) do
    "it is one part of a split archive; upload a single-file ZIP"
  end

  defp describe_zip_error({:encrypted, entry_name}), do: "#{entry_name} is password-protected"

  defp describe_zip_error({:unsupported_compression, entry_name}) do
    "#{entry_name} uses a compression method other than Deflate or Store"
  end

  defp describe_zip_error({reason, entry_name})
       when reason in [:bad_crc, :corrupt_entry, :truncated, :bad_local_header] do
    "#{entry_name} is damaged inside the archive"
  end

  defp describe_zip_error(reason) when is_binary(reason), do: reason

  @spec process_document_entry(String.t(), binary(), module()) ::
          {:pdf, [String.t()]}
          | {:zip_empty, String.t()}
          | {:zip_error, {String.t(), ZipExtractor.error()}}
          | {:skipped, String.t()}
  defp process_document_entry(client_name, binary, adapter) do
    downcased = String.downcase(client_name)

    cond do
      String.ends_with?(downcased, ".pdf") ->
        key = storage_key(client_name, binary)
        :ok = adapter.write(key, binary)
        {:pdf, [key]}

      String.ends_with?(downcased, ".zip") ->
        case ZipExtractor.extract_pdfs(binary) do
          {:ok, []} ->
            {:zip_empty, client_name}

          {:ok, pdf_entries} ->
            keys =
              Enum.map(pdf_entries, fn {inner_path, pdf_binary} ->
                key = storage_key(inner_path, pdf_binary)
                :ok = adapter.write(key, pdf_binary)
                key
              end)

            {:pdf, keys}

          {:error, reason} ->
            {:zip_error, {client_name, reason}}
        end

      true ->
        {:skipped, client_name}
    end
  end

  @spec process_folder_entry(String.t(), binary(), module()) ::
          {:pdf, [String.t()]} | {:skipped, String.t()}
  defp process_folder_entry(client_name, binary, adapter) do
    if String.ends_with?(String.downcase(client_name), ".pdf") do
      key = storage_key(client_name, binary)
      :ok = adapter.write(key, binary)
      {:pdf, [key]}
    else
      {:skipped, client_name}
    end
  end

  @spec storage_key(String.t(), binary()) :: String.t()
  defp storage_key(filename, binary) do
    hash =
      :sha256
      |> :crypto.hash(binary)
      |> Base.encode16(case: :lower)
      |> String.slice(0, 12)

    safe_name =
      filename
      |> Path.basename(".pdf")
      |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")

    Adapters.build_key("books", "#{safe_name}_#{hash}")
  end

  @impl Phoenix.LiveView
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_page={:upload}>
      <.header>
        Upload documents
        <:subtitle>Add PDFs to the library that Chat and Search answer from.</:subtitle>
      </.header>

      <.rejected_archives :if={@rejected_archives != []} archives={@rejected_archives} />

      <%= case @status do %>
        <% :idle -> %>
          <.upload_form uploads={@uploads} />
        <% :processing -> %>
          <.processing_indicator />
        <% :done -> %>
          <.results_panel results={@results} error={@error} skipped_count={@skipped_count} />
        <% :error -> %>
          <.error_panel error={@error} />
      <% end %>
    </Layouts.app>
    """
  end

  # Both file inputs are hidden (`sr-only`) inside the label that stands for
  # them, so each still takes the keyboard focus and opens its picker, and the
  # browser's own file control, which is wider than a phone, is never drawn.
  defp upload_form(assigns) do
    ~H"""
    <form id="upload-form" phx-submit="upload" phx-change="validate" class="space-y-4">
      <%!-- From `sm` up, a drop zone; below it, where there is nothing to
      drag, the same label is a button. --%>
      <label
        id="upload-dropzone"
        for={@uploads.documents.ref}
        phx-drop-target={@uploads.documents.ref}
        class="flex cursor-pointer flex-col items-center gap-2 rounded-box border-base-content/30 text-center focus-within:outline-2 focus-within:outline-offset-2 focus-within:outline-primary sm:border-2 sm:border-dashed sm:px-4 sm:py-10 sm:hover:border-primary"
      >
        <.icon name="hero-arrow-up-tray" class="hidden size-10 opacity-60 sm:block" />
        <span class="hidden sm:block">
          Drop files here, or <span class="link link-primary">choose them</span>
        </span>
        <span class="btn btn-outline w-full sm:hidden">
          <.icon name="hero-arrow-up-tray" class="size-5" /> Choose files
        </span>
        <span id="upload-limits" class="text-sm text-base-content/70">
          PDF or ZIP, up to {@uploads.documents.max_entries} files, {max_size(@uploads.documents)} each
        </span>
        <.live_file_input upload={@uploads.documents} class="sr-only" />
      </label>

      <div class="divider text-sm text-base-content/70">or</div>

      <div id="upload-folder" class="flex flex-col items-center gap-2 text-center">
        <label class="btn btn-outline w-full focus-within:outline-2 focus-within:outline-offset-2 focus-within:outline-primary sm:w-auto">
          <.icon name="hero-folder-open" class="size-5" /> Choose a folder
          <.live_file_input upload={@uploads.folder} webkitdirectory class="sr-only" />
        </label>
        <span class="text-sm text-base-content/70">
          The PDFs in one folder, up to {@uploads.folder.max_entries} files, {max_size(
            @uploads.folder
          )} each
        </span>
      </div>

      <.queue :if={queued?(@uploads)} uploads={@uploads} />

      <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
        <.button id="upload-submit" type="submit" variant="primary" disabled={not ready?(@uploads)}>
          Upload and ingest
        </.button>
        <p :if={blocked?(@uploads)} id="upload-blocked" class="text-sm text-base-content/70">
          Remove the files that cannot be uploaded to continue.
        </p>
      </div>
    </form>
    """
  end

  defp queue(assigns) do
    ~H"""
    <div id="upload-queue" class="space-y-2">
      <ul class="list rounded-box border border-base-300 bg-base-100">
        <.queue_entry
          :for={{upload, entry} <- queued_entries(@uploads)}
          entry={entry}
          upload_name={upload.name}
          errors={upload_errors(upload, entry)}
        />
      </ul>
      <%!-- More files than one upload takes is an error of the whole queue,
      not of any one file in it. --%>
      <p
        :for={upload <- [@uploads.documents, @uploads.folder]}
        :if={upload_errors(upload) != []}
        data-part="queue-error"
        class="flex items-center gap-2 text-sm text-error"
      >
        <.icon name="hero-exclamation-circle" class="size-5 shrink-0" />
        <span :for={error <- upload_errors(upload)}>
          {upload_error_to_string(error)}: this takes {upload.max_entries} at a time.
        </span>
      </p>
    </div>
    """
  end

  defp queue_entry(assigns) do
    ~H"""
    <li id={"upload-entry-#{@entry.ref}"} class="list-row items-center">
      <.icon
        name={if @errors == [], do: "hero-document", else: "hero-exclamation-circle"}
        class={["size-5", if(@errors == [], do: "opacity-60", else: "text-error")]}
      />
      <div class="min-w-0">
        <p data-part="name" class="wrap-anywhere">{@entry.client_name}</p>
        <p data-part="size" class="text-sm text-base-content/70">
          {format_size(@entry.client_size)}
        </p>
        <progress
          :if={@errors == []}
          class="progress progress-primary mt-1 block w-full"
          value={@entry.progress}
          max="100"
          aria-label={"Upload progress of #{@entry.client_name}"}
        >
          {@entry.progress}%
        </progress>
        <p :for={error <- @errors} data-part="error" class="text-sm text-error">
          {upload_error_to_string(error)}
        </p>
      </div>
      <button
        type="button"
        phx-click="cancel-upload"
        phx-value-ref={@entry.ref}
        phx-value-upload={@upload_name}
        aria-label={"Remove #{@entry.client_name}"}
        class="btn btn-ghost btn-sm btn-square"
      >
        <.icon name="hero-x-mark" class="size-5" />
      </button>
    </li>
    """
  end

  defp rejected_archives(assigns) do
    ~H"""
    <.notice id="rejected-archives" kind={:warning} title="These archives were not ingested:">
      <ul class="ml-5 list-disc">
        <li :for={archive <- @archives} class="wrap-anywhere">{archive}</li>
      </ul>
    </.notice>
    """
  end

  # Ingestion reports nothing until it is done, and it runs in a task this
  # LiveView owns: leaving the page, by closing the tab or by following a
  # link, stops it. The page has to say both for as long as that is so.
  defp processing_indicator(assigns) do
    ~H"""
    <.working id="upload-working">
      Ingesting your documents. A large PDF takes minutes, and there is no progress to show until it is done.
      <strong id="upload-keep-open" class="block font-semibold text-base-content">
        Keep this tab open, on this page: leaving it stops the ingestion.
      </strong>
    </.working>
    """
  end

  defp results_panel(assigns) do
    ~H"""
    <.notice id="upload-results" kind={results_kind(@results, @error)} title="Ingestion complete">
      <p class="wrap-anywhere">{@results.message}</p>
      <p class="flex flex-wrap gap-x-4">
        <span data-part="indexed">{@results.indexed} indexed</span>
        <span :if={@results.failed > 0} data-part="failed">{@results.failed} failed</span>
        <span :if={@skipped_count > 0} data-part="skipped">
          {@skipped_count} non-PDF files skipped
        </span>
      </p>
      <p :if={@error}>{@error}</p>
    </.notice>

    <%!-- The documents list joins these when its route exists (#380). --%>
    <div id="upload-onward" class="flex flex-wrap items-center gap-2">
      <button id="upload-more" type="button" phx-click="reset" class="btn btn-outline">
        Upload more
      </button>
      <.link navigate={~p"/chat"} class="btn btn-ghost">
        Ask about them in Chat <.icon name="hero-arrow-right" class="size-5" />
      </.link>
    </div>
    """
  end

  defp error_panel(assigns) do
    ~H"""
    <.notice id="upload-error" kind={:error}>
      <span class="wrap-anywhere">{@error}</span>
    </.notice>
    <button id="upload-retry" type="button" phx-click="reset" class="btn btn-outline">
      Try again
    </button>
    """
  end

  # The two uploads the form holds, in the order the queue lists them.
  @spec queued_entries(map()) :: [
          {Phoenix.LiveView.UploadConfig.t(), Phoenix.LiveView.UploadEntry.t()}
        ]
  defp queued_entries(uploads) do
    for upload <- [uploads.documents, uploads.folder],
        entry <- upload.entries,
        do: {upload, entry}
  end

  @spec queued?(map()) :: boolean()
  defp queued?(uploads), do: queued_entries(uploads) != []

  # A refused file, or more files than an upload takes, is an error on the
  # upload. While there is one the browser sends nothing on submit, so the
  # button is disabled rather than left to do nothing.
  @spec blocked?(map()) :: boolean()
  defp blocked?(uploads), do: uploads.documents.errors != [] or uploads.folder.errors != []

  @spec ready?(map()) :: boolean()
  defp ready?(uploads), do: queued?(uploads) and not blocked?(uploads)

  # The size limit as the page states it: the decimal megabytes it is
  # configured in, not the binary ones format_size/1 shows a file's size in.
  @spec max_size(Phoenix.LiveView.UploadConfig.t()) :: String.t()
  defp max_size(upload), do: "#{div(upload.max_file_size, 1_000_000)} MB"

  # Nothing ingested is an error; some documents failing is a warning.
  @spec results_kind(Cake.Pipelines.ingest_summary(), String.t() | nil) ::
          :success | :warning | :error
  defp results_kind(_results, error) when is_binary(error), do: :error
  defp results_kind(%{failed: failed}, nil) when failed > 0, do: :warning
  defp results_kind(_results, nil), do: :success

  @spec format_size(non_neg_integer()) :: String.t()
  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  @spec upload_error_to_string(atom()) :: String.t()
  defp upload_error_to_string(:too_large), do: "File is too large (max 100 MB)"
  defp upload_error_to_string(:not_accepted), do: "File type not accepted"
  defp upload_error_to_string(:too_many_files), do: "Too many files"
  defp upload_error_to_string(error), do: "Upload error: #{inspect(error)}"
end
