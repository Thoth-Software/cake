defmodule CakeWeb.ChatLive do
  use CakeWeb, :live_view

  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    conversation_id = Ecto.UUID.generate()

    opts = %{
      id: conversation_id,
      search: Cake.Search.OpenSearch,
      reply_to: self(),
      embedder: Application.fetch_env!(:cake, :default_embedding_model),
      response_model: Application.fetch_env!(:cake, :default_response_model),
      provider: Application.fetch_env!(:cake, :default_provider),
      gds: Cake.Books.ParsedBook
    }

    {:ok, pid} = Cake.Conversation.start(opts)
    Process.monitor(pid)

    {:ok,
     assign(socket,
       convo_pid: pid,
       messages: [],
       loading: false,
       citations: [],
       form: to_form(%{"question" => ""})
     )}
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("submit", %{"question" => question}, socket) do
    if String.trim(question) == "" do
      {:noreply, socket}
    else
      Cake.Conversation.autoask(socket.assigns.convo_pid, question)

      {:noreply,
       assign(socket,
         messages: [%{role: :user, text: question} | socket.assigns.messages],
         loading: true,
         form: to_form(%{"question" => ""})
       )}
    end
  end

  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:convo_response, response, citations}, socket) do
    {:noreply,
     assign(socket,
       messages: [
         %{role: :assistant, text: response, citations: citations} | socket.assigns.messages
       ],
       loading: false,
       citations: citations
     )}
  end

  def handle_info({:convo_error, error}, socket) do
    {:noreply,
     assign(socket,
       messages: [%{role: :assistant, text: "Error: #{inspect(error)}"} | socket.assigns.messages],
       loading: false
     )}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
    {:noreply,
     assign(socket,
       messages: [
         %{role: :assistant, text: "Error: conversation process crashed (#{inspect(reason)})"}
         | socket.assigns.messages
       ],
       loading: false
     )}
  end

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto p-4">
      <h1 class="text-2xl font-bold mb-4">Cake Chat</h1>

      <div class="space-y-4 mb-8">
        <div
          :for={{msg, i} <- Enum.with_index(Enum.reverse(@messages))}
          id={"msg-#{i}"}
          class={[
            "p-3 rounded-lg max-w-xl",
            msg.role == :user && "ml-auto bg-blue-100 text-right",
            msg.role == :assistant && "mr-auto bg-gray-100"
          ]}
        >
          <span class="text-xs font-semibold text-gray-500 block mb-1">
            {if msg.role == :user, do: "You", else: "Cake"}
          </span>
          <span class="text-sm whitespace-pre-wrap">{msg.text}</span>

          <%!-- Citations (assistant messages only) --%>
          <div
            :if={msg[:citations] != nil and msg[:citations] != []}
            class="mt-2 text-sm text-gray-600 border-t pt-2"
          >
            <div class="font-semibold mb-1">Sources:</div>
            <div class="space-y-1">
              <div :for={cite <- msg.citations} class="relative group inline-block">
                <a href={"/books/download/#{cite.source_ref}"} class="text-blue-600 hover:underline">
                  [{cite.new_index}] {cite.label}
                </a>
                <%!-- Hover tooltip --%>
                <div class="hidden group-hover:block absolute z-10 bottom-full left-0 mb-1 w-80 p-3 bg-gray-800 text-white text-xs rounded shadow-lg">
                  {cite.preview}
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div :if={@loading} class="text-gray-500 italic mb-4">Thinking...</div>

      <.simple_form for={@form} phx-submit="submit">
        <.input field={@form[:question]} type="text" placeholder="Ask a question..." />
        <:actions>
          <.button type="submit" disabled={@loading}>Send</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end
end
