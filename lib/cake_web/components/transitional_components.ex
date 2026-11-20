defmodule CakeWeb.TransitionalComponents do
  @moduledoc """
  Components the Phoenix 1.8 `CakeWeb.CoreComponents` no longer has, kept
  because pages not yet restyled still call them (#374).

  They are the Phoenix 1.7 implementations, unchanged, with their 1.7
  classes. Nothing new should call them: a page that is restyled moves to
  `<.form>` and the daisyUI classes of `CakeWeb.CoreComponents`, and when a
  component here loses its last caller it is deleted. When the module is
  empty it goes, with its import in the HTML helpers of `CakeWeb`.

    * `simple_form/1` - the auth pages, `CakeWeb.ChatLive` and
      `CakeWeb.SearchLive`.
    * `error/1` - `CakeWeb.UserRegistrationLive`,
      `CakeWeb.UserResetPasswordLive` and `CakeWeb.UploadLive`.
      (`CakeWeb.CoreComponents.input/1` renders its own field errors; this
      one is for a message that belongs to no field.)

  1.8 also dropped `modal/1`, `back/1`, `label/1`, `show_modal/2` and
  `hide_modal/2`. Nothing called them, so they are not kept.
  """

  use Phoenix.Component

  import CakeWeb.CoreComponents, only: [icon: 1]

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
      <div class="mt-10 space-y-8 bg-white">
        {render_slot(@inner_block, f)}
        <div :for={action <- @actions} class="mt-2 flex items-center justify-between gap-6">
          {render_slot(action, f)}
        </div>
      </div>
    </.form>
    """
  end

  @doc """
  Generates a generic error message.
  """
  slot :inner_block, required: true

  @spec error(map()) :: Phoenix.LiveView.Rendered.t()
  def error(assigns) do
    ~H"""
    <p class="mt-3 flex gap-3 text-sm leading-6 text-rose-600">
      <.icon name="hero-exclamation-circle-mini" class="mt-0.5 h-5 w-5 flex-none" />
      {render_slot(@inner_block)}
    </p>
    """
  end
end
