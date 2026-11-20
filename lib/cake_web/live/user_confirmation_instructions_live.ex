defmodule CakeWeb.UserConfirmationInstructionsLive do
  use CakeWeb, :live_view

  alias Cake.Accounts

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>
        No confirmation instructions received?
        <:subtitle>We'll send a new confirmation link to your inbox</:subtitle>
      </.header>

      <div class="card card-border bg-base-100">
        <div class="card-body">
          <%!-- A one-field request: nothing worth recovering after a reconnect. --%>
          <.form
            for={@form}
            id="resend_confirmation_form"
            phx-submit="send_instructions"
            phx-auto-recover="ignore"
          >
            <.input field={@form[:email]} type="email" label="Email" autocomplete="email" required />
            <.button phx-disable-with="Sending..." class="btn btn-primary mt-2 w-full">
              Resend confirmation instructions
            </.button>
          </.form>
        </div>
      </div>

      <p class="text-center text-sm">
        <.link href={~p"/users/register"} class="link link-hover">Register</.link>
        | <.link href={~p"/users/log_in"} class="link link-hover">Log in</.link>
      </p>
    </Layouts.app>
    """
  end

  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Confirm account", form: to_form(%{}, as: "user"))}
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("send_instructions", %{"user" => %{"email" => email}}, socket) do
    email
    |> Accounts.get_user_by_email()
    |> List.wrap()
    |> Enum.each(fn user ->
      Accounts.deliver_user_confirmation_instructions(
        user,
        &url(~p"/users/confirm/#{&1}")
      )
    end)

    info =
      "If your email is in our system and it has not been confirmed yet, you will receive an email with instructions shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> redirect(to: ~p"/")}
  end
end
