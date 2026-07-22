defmodule CakeWeb.UploadLive do
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
       status: :idle,
       results: nil,
       error: nil,
       skipped_count: 0
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
    {:noreply, assign(socket, status: :idle, results: nil, error: nil, skipped_count: 0)}
  end

  @impl Phoenix.LiveView
  @spec handle_async(atom(), {:ok, term()} | {:exit, term()}, Phoenix.LiveView.Socket.t()) ::
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

  def handle_async(:ingest, {:exit, reason}, socket) do
    Logger.error("UploadLive ingestion task crashed: #{inspect(reason)}")

    {:noreply,
     assign(socket, status: :error, error: "Ingestion failed unexpectedly. Please try again.")}
  end

  @typep upload_result ::
           {:pdf, [String.t()]}
           | {:zip_empty, String.t()}
           | {:zip_error, {String.t(), term()}}
           | {:skipped, String.t()}

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
           error: "Failed to process #{name}: #{inspect(reason)}"
         )}

      all_keys == [] ->
        {:noreply,
         assign(socket, status: :error, error: "No PDF files found in the uploaded files.")}

      true ->
        socket =
          socket
          |> assign(status: :processing, skipped_count: skipped)
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

  @spec collect_zip_errors([upload_result()]) :: [{String.t(), term()}]
  defp collect_zip_errors(results) do
    Enum.flat_map(results, fn
      {:zip_error, info} -> [info]
      {:zip_empty, name} -> [{name, "ZIP contained no PDF files"}]
      _ -> []
    end)
  end

  @spec process_document_entry(String.t(), binary(), module()) ::
          {:pdf, [String.t()]}
          | {:zip_empty, String.t()}
          | {:zip_error, {String.t(), term()}}
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
    <div class="max-w-2xl mx-auto p-4">
      <h1 class="text-2xl font-bold mb-4">Upload Documents</h1>

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
    </div>
    """
  end

  defp upload_form(assigns) do
    ~H"""
    <form id="upload-form" phx-submit="upload" phx-change="validate">
      <div class="space-y-6">
        <div>
          <label class="block text-sm font-medium text-gray-700 mb-2">
            Upload Files (PDFs or ZIP archives)
          </label>
          <.live_file_input upload={@uploads.documents} />
        </div>

        <div>
          <label class="block text-sm font-medium text-gray-700 mb-2">
            Upload Folder
          </label>
          <.live_file_input upload={@uploads.folder} webkitdirectory />
        </div>

        <.entry_list entries={@uploads.documents.entries} upload_name="documents" />
        <.entry_list entries={@uploads.folder.entries} upload_name="folder" />

        <.entry_errors upload={@uploads.documents} />
        <.entry_errors upload={@uploads.folder} />

        <button
          type="submit"
          disabled={no_valid_entries?(@uploads)}
          class="w-full rounded-lg bg-zinc-900 px-4 py-2 text-sm font-semibold text-white hover:bg-zinc-700 disabled:opacity-50 disabled:cursor-not-allowed"
        >
          Upload and Ingest
        </button>
      </div>
    </form>
    """
  end

  defp entry_list(assigns) do
    ~H"""
    <ul :if={@entries != []} class="space-y-2">
      <li :for={entry <- @entries} class="flex items-center justify-between bg-gray-50 rounded p-2">
        <div class="flex-1 min-w-0">
          <span class="text-sm truncate block">{entry.client_name}</span>
          <span class="text-xs text-gray-500">{format_size(entry.client_size)}</span>
          <div :if={entry.progress > 0 and entry.progress < 100} class="mt-1">
            <div class="w-full bg-gray-200 rounded-full h-1.5">
              <div class="bg-blue-600 h-1.5 rounded-full" style={"width: #{entry.progress}%"}></div>
            </div>
          </div>
        </div>
        <button
          type="button"
          phx-click="cancel-upload"
          phx-value-ref={entry.ref}
          phx-value-upload={@upload_name}
          class="ml-2 text-red-500 hover:text-red-700 text-sm"
        >
          &times;
        </button>
      </li>
    </ul>
    """
  end

  defp entry_errors(assigns) do
    ~H"""
    <div
      :for={entry <- @upload.entries}
      :if={upload_errors(@upload, entry) != []}
      class="text-red-600 text-sm"
    >
      <span>{entry.client_name}:</span>
      <span :for={msg <- upload_errors(@upload, entry)}>{upload_error_to_string(msg)}</span>
    </div>
    """
  end

  defp processing_indicator(assigns) do
    ~H"""
    <div class="flex items-center justify-center p-8">
      <div class="animate-spin rounded-full h-8 w-8 border-b-2 border-zinc-900 mr-3"></div>
      <span class="text-gray-600">Processing documents...</span>
    </div>
    """
  end

  defp results_panel(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="rounded-lg border p-4">
        <h2 class="text-lg font-semibold mb-2">Ingestion Complete</h2>
        <p class="text-sm text-gray-600">{@results.message}</p>
        <div class="mt-2 flex gap-4 text-sm">
          <span class="text-green-600">{@results.indexed} indexed</span>
          <span :if={@results.failed > 0} class="text-red-600">{@results.failed} failed</span>
          <span :if={@skipped_count > 0} class="text-gray-500">
            {@skipped_count} non-PDF files skipped
          </span>
        </div>
      </div>

      <div :if={@error} class="p-3 bg-yellow-100 text-yellow-800 rounded text-sm">
        {@error}
      </div>

      <button
        type="button"
        phx-click="reset"
        class="rounded-lg bg-zinc-900 px-4 py-2 text-sm font-semibold text-white hover:bg-zinc-700"
      >
        Upload More
      </button>
    </div>
    """
  end

  defp error_panel(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="p-4 bg-red-100 text-red-700 rounded">
        {@error}
      </div>
      <button
        type="button"
        phx-click="reset"
        class="rounded-lg bg-zinc-900 px-4 py-2 text-sm font-semibold text-white hover:bg-zinc-700"
      >
        Try Again
      </button>
    </div>
    """
  end

  @spec no_valid_entries?(map()) :: boolean()
  defp no_valid_entries?(uploads) do
    uploads.documents.entries == [] and uploads.folder.entries == []
  end

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
