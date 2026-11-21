defmodule CakeWeb.TransitionalComponents do
  @moduledoc """
  The one component the Phoenix 1.8 `CakeWeb.CoreComponents` no longer has
  that a page not yet restyled still calls (#374).

  It is the Phoenix 1.7 implementation, unchanged, with its 1.7 classes.
  Nothing new should call it: a page that is restyled moves to `<.form>`
  and the daisyUI classes of `CakeWeb.CoreComponents`. When it loses its
  last caller it is deleted, and the module goes with it, with its import
  in the HTML helpers of `CakeWeb`.

    * `simple_form/1` - `CakeWeb.ChatLive`, until #378 rebuilds the chat.

  `error/1` was here for the auth pages; they now use
  `CakeWeb.CoreComponents.notice/1` for a message that belongs to no field
  (#377).

  1.8 also dropped `modal/1`, `back/1`, `label/1`, `show_modal/2` and
  `hide_modal/2`. Nothing called them, so they are not kept.
  """

  use Phoenix.Component

  @doc """
  Renders a simple form.

  ## Examples

      <.simple_form for={@form} phx-change="validate" phx-submit="save">
        <.input field={@form[:email]} label="Email"/>
        <.input field={@form[:username]} label="Username" />
        <:actions>
          <.button>Save</.button>
        </:actions>
      </.simple_form>
  """
  attr :for, :any, required: true, doc: "the data structure for the form"
  attr :as, :any, default: nil, doc: "the server side parameter to collect all input under"

  attr :rest, :global,
    include: ~w(autocomplete name rel action enctype method novalidate target multipart),
    doc: "the arbitrary HTML attributes to apply to the form tag"

  slot :inner_block, required: true
  slot :actions, doc: "the slot for form actions, such as a submit button"

  @spec simple_form(map()) :: Phoenix.LiveView.Rendered.t()
  def simple_form(assigns) do
    ~H"""
    <.form :let={f} for={@for} as={@as} {@rest}>
      <div class="mt-10 space-y-8">
        {render_slot(@inner_block, f)}
        <div :for={action <- @actions} class="mt-2 flex items-center justify-between gap-6">
          {render_slot(action, f)}
        </div>
      </div>
    </.form>
    """
  end
end
