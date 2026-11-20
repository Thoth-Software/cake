defmodule CakeWeb.UserLoginLive do
  use CakeWeb, :live_view

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto max-w-sm">
        <.header class="text-center">
          Log in to account
          <:subtitle>
            Don't have an account?
            <.link navigate={~p"/users/register"} class="link link-hover link-primary font-semibold">
              Sign up
            </.link>
            for an account now.
          </:subtitle>
        </.header>

        <.simple_form for={@form} id="login_form" action={~p"/users/log_in"} phx-update="ignore">
          <.input field={@form[:username]} type="text" label="Username" required />
          <.input field={@form[:password]} type="password" label="Password" required />

          <:actions>
            <.input field={@form[:remember_me]} type="checkbox" label="Keep me logged in" />
            <.link href={~p"/users/reset_password"} class="text-sm font-semibold">
              Forgot your password?
            </.link>
          </:actions>
          <:actions>
            <.button phx-disable-with="Logging in..." class="btn btn-primary w-full">
              Log in <span aria-hidden="true">→</span>
            </.button>
          </:actions>
        </.simple_form>
      </div>
    </Layouts.app>
    """
  end

  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:ok, Phoenix.LiveView.Socket.t(), keyword()}
  def mount(_params, _session, socket) do
    username = Phoenix.Flash.get(socket.assigns.flash, :username)
    form = to_form(%{"username" => username}, as: "user")
    {:ok, assign(socket, page_title: "Log in", form: form), temporary_assigns: [form: form]}
  end
end
